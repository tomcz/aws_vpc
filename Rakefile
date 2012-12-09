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

desc "Setup VPC"
task :setup_vpc => :check_credentials do
  bastion_hosts = @aws.create_vpc
  bastion_hosts.each do |host|
    SSHDriver.wait_for_ssh_connection host.public_ip
    write_connect_script host
  end
end

desc "Destroy VPC"
task :destroy_vpc => :check_credentials do
  @aws.destroy_vpc
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
