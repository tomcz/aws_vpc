ROOT = File.expand_path(File.dirname(__FILE__))
$LOAD_PATH.unshift File.join(ROOT, 'lib')

require 'colorize'
require 'ssh_driver'
require 'aws_driver'
require 'highline/import'
require 'rake/clean'
require 'json'

OUTPUT = 'build'
CLEAN << OUTPUT
directory OUTPUT

TARBALL_NAME = 'chef-solo.tar.gz'

task :default => :check_credentials

task :check_credentials do
  vpc_name = ENV['VPC_NAME'] || 'midkemia'
  vpc_conf = "config/vpc/#{vpc_name}.yml"
  raise "#{vpc_conf} does not exist!" unless File.file? vpc_conf
  puts "Using configuration from #{vpc_conf}".cyan
  @aws = AWSDriver.new(ROOT, vpc_conf)
  unless @aws.credentials?
    access_key_id = ask('@aws Access Key ID? ')
    secret_access_key = ask('@aws Secret Access Key? ')
    @aws.save_credentials access_key_id.to_s, secret_access_key.to_s
  end
end

desc "Make VPC"
task :make_vpc => [:check_credentials, OUTPUT] do
  bastion_hosts = @aws.make_vpc
  bastion_hosts.each do |instance|
    SSHDriver.start(instance.public_ip, instance.user, instance.keyfile) do |ssh|
      provision_instance(ssh, bastion_host_config(instance))
    end
  end
  bastion_hosts.each do |instance|
    write_connect_script instance
  end
end

desc "Delete VPC"
task :delete_vpc => :check_credentials do
  Dir[connect_script_name('*')].each { |script| File.delete script }
  @aws.delete_vpc
end

def bastion_host_config(instance)
  update_config_file('chef/nodes/bastion.json') do |config|
    config['bastion'] = {
        'user' => instance.user,
        'ssh_hosts' => instance.hosts,
    }
  end
end

def update_config_file(config_file)
  config = open(config_file) { |fp| JSON.parse fp.read }
  yield config
  output = File.join(OUTPUT, File.basename(config_file))
  open(output, 'w') { |fp| fp.puts JSON.pretty_generate(config) }
  output
end

def provision_instance(ssh, config_file)
  install_chef_solo ssh
  config_file_name = File.basename(config_file)
  ssh.upload config_file, "chef/#{config_file_name}"
  ssh.exec! "sudo chef-solo -c ~/chef/solo.rb -j ~/chef/#{config_file_name}"
end

def install_chef_solo(ssh)
  ssh.exec! 'sudo apt-get -y update'
  ssh.exec! 'sudo apt-get -y upgrade'
  unless ssh.exec('chef-solo --version').success
    ssh.exec! 'curl -L http://www.opscode.com/chef/install.sh | sudo bash'
  end
  tarball_file = File.join(OUTPUT, TARBALL_NAME)
  sh "tar czf #{tarball_file} chef"
  ssh.exec 'rm -rf chef*'
  ssh.exec "mkdir /tmp/chef-solo"
  ssh.upload tarball_file, TARBALL_NAME
  ssh.exec! "tar xzf #{TARBALL_NAME}"
end

def write_connect_script(instance)
  filename = connect_script_name instance.name
  namespace = OpenStruct.new(keyfile: instance.keyfile, user: instance.user, host: instance.public_ip)
  results = ERB.new(File.read('lib/connect.sh.erb')).result(namespace.instance_eval { binding })
  File.open(filename, 'w') { |f| f.write(results) }
  File.chmod(0755, filename)
  puts "Connect to #{instance.name} using ./#{filename}".green
end

def connect_script_name(node_name)
  "connect_#{node_name}"
end
