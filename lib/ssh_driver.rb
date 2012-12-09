require 'net/ssh'
require 'net/scp'
require 'ostruct'
require 'colorize'

class SSHDriver

  def initialize(ssh)
    @ssh = ssh
  end

  def self.wait_for_ssh_connection(hostname)
    puts "Waiting for SSH server on #{hostname} ..."
    sleep 5 while !system("nc -z -v -w 10 #{hostname} 22")
  end

  def self.start(hostname, user, keyfile, &block)
    self.wait_for_ssh_connection hostname
    # use /dev/null as known_hosts to stop ephemeral EC2 signatures from filling up the normal known_hosts file
    Net::SSH.start(hostname, user, :keys => [keyfile], :keys_only => true, :user_known_hosts_file => %w(/dev/null)) do |ssh|
      block.call(SSHDriver.new(ssh))
    end
  end

  def exec!(command)
    exec command, true
  end

  def exec(command, check_exit_code = false)
    puts ">> #{command}".green
    result = OpenStruct.new(:output => '')
    @ssh.open_channel do |channel|
      channel.request_pty do |ch, success|
        raise 'FAILED: could not obtain pty' unless success
      end
      channel.exec(command) do |ch, success|
        raise "FAILED: could not execute #{command}" unless success

        channel.on_data do |ch, data|
          result.output += data
          print data
        end

        channel.on_extended_data do |ch, type, data|
          result.output += data
          print data
        end

        channel.on_request("exit-status") do |ch, data|
          result.exit_code = data.read_long
        end

        channel.on_request("exit-signal") do |ch, data|
          result.exit_signal = data.read_long
        end
      end
    end
    @ssh.loop
    result.success = (result.exit_code == 0)
    puts # output may not end with a new line
    if check_exit_code && !result.success
      raise "FAILED: bad exit code [#{result.exit_code}] for #{command}"
    end
    result
  end

  def upload(local_file, remote_file)
    puts ">> scp #{local_file} #{remote_file}".green
    @ssh.scp.upload!(local_file, remote_file) do |ch, name, sent, total|
      puts "#{name}: #{sent}/#{total}"
    end
  end

end
