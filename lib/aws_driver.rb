require 'aws'
require 'yaml'
require 'hashie'
require 'ostruct'
require 'fileutils'

class AWSDriver

  ANYWHERE = '0.0.0.0/0'

  attr_reader :credentials, :ssh_key_file

  def initialize(config_dir, config_file)
    @credentials = File.join(config_dir, '.aws')
    @ssh_key_file = File.join(config_dir, '.key')
    @config = Hashie::Mash.new(YAML.load_file(config_file))
  end

  def make_vpc
    ec2 = connect_to_ec2
    vpc = get_or_create_vpc ec2
    internet_gateway = ensure_internet_gateway_attached ec2, vpc
    route_table = get_or_create_route_table vpc, internet_gateway
    @config.subnets.map do |config|
      subnet = get_or_create_subnet vpc, config, route_table
      get_or_create_bastion_host ec2, vpc, config.bastion_host, subnet
    end
  end

  def get_or_create_vpc(ec2)
    vpc = find_vpc ec2
    unless vpc
      puts "Creating [#{@config.name}] vpc"
      vpc = ec2.vpcs.create @config.cidr_block
      wait_until_state vpc, :available
      tag_with_name vpc, @config.name
    end
    vpc
  end

  def find_vpc(ec2)
    find_tagged_with_name ec2.vpcs, @config.name
  end

  def ensure_internet_gateway_attached(ec2, vpc)
    internet_gateway = vpc.internet_gateway
    unless internet_gateway
      internet_gateway = get_or_create_internet_gateway ec2
      vpc.internet_gateway = internet_gateway
    end
    internet_gateway
  end

  def get_or_create_internet_gateway(ec2)
    gateway = find_tagged_with_name ec2.internet_gateways, @config.name
    unless gateway
      puts "Creating [#{@config.name}] internet gateway"
      gateway = ec2.internet_gateways.create
      wait_until_exists gateway
      tag_with_name gateway, @config.name
    end
    gateway
  end

  def get_or_create_route_table(vpc, internet_gateway, name = 'public', destination = ANYWHERE)
    route_table = find_tagged_with_name vpc.route_tables, name
    unless route_table
      puts "Creating [#{name}] route table"
      route_table = vpc.route_tables.create vpc: vpc
      tag_with_name route_table, name
      route_table.create_route destination, internet_gateway: internet_gateway
    end
    route_table
  end

  def get_or_create_subnet(vpc, config, route_table)
    subnet = find_tagged_with_name vpc.subnets, config.name
    unless subnet
      puts "Creating [#{config.name}] subnet in [#{config.availability_zone}]"
      subnet = vpc.subnets.create config.cidr_block, vpc: vpc, availability_zone: config.availability_zone
      tag_with_name subnet, config.name
      subnet.set_route_table route_table
    end
    subnet
  end

  def get_or_create_bastion_host(ec2, vpc, name, subnet)
    image_id = @config.defaults.image_id
    login_user = @config.defaults.image_login_user
    instance_type = @config.defaults.instance_type
    ssh_hosts = @config.subnets.map { |sn| sn.ssh_hosts }

    key_pair = get_or_create_bastion_host_key ec2
    security_group = get_or_create_bastion_host_security_group vpc
    instance = get_or_create_instance ec2, name, image_id, instance_type, key_pair, security_group, subnet
    elastic_ip = associate_elastic_ip ec2, name, instance

    OpenStruct.new(name: name, public_ip: elastic_ip, user: login_user, keyfile: @ssh_key_file, hosts: ssh_hosts)
  end

  def get_or_create_bastion_host_key(ec2)
    key_name = "#{@config.name}-bastion"
    key_object_name = "#{key_name}.pem"
    key_pair = get_or_create_key_pair ec2, key_name, key_object_name
    fetch_key key_object_name, @ssh_key_file
    key_pair
  end

  def get_or_create_key_pair(ec2, key_name, object_name)
    key_pair = find_key_pair ec2, key_name
    unless key_pair
      puts "Creating #{key_name} key pair"
      key_pair = ec2.key_pairs.create key_name
      upload_key key_pair, object_name
    end
    key_pair
  end

  def find_key_pair(ec2, key_name)
    ec2.key_pairs.filter('key-name', key_name).first
  end

  def upload_key(key_pair, object_name)
    puts "Uploading [#{object_name}] to S3 bucket"
    object = ssh_key_object object_name
    object.write key_pair.private_key,
                 :content_type => 'application/octet-stream',
                 :server_side_encryption => :aes256
  end

  def fetch_key(object_name, output)
    unless File.file? output
      puts "Saving [#{object_name}] from S3 bucket to [#{output}]"
      object = ssh_key_object object_name
      File.open(output, 'w') { |out| out.write object.read }
      File.chmod(0600, output)
    end
  end

  def ssh_key_object(object_name)
    s3 = connect_to_s3
    bucket_name = "#{@config.key_bucket_prefix}-#{s3.config.access_key_id}".downcase
    bucket = s3.buckets[bucket_name]
    unless bucket.exists?
      region = @config.key_bucket_region || 'us-standard'
      puts "Creating [#{bucket_name}] S3 bucket in [#{region}]"
      bucket = s3.buckets.create bucket_name, location_constraint: @config.key_bucket_region
    end
    bucket.objects[object_name]
  end

  def get_or_create_bastion_host_security_group(vpc)
    security_group_name = "#{@config.name}-bastion"
    security_group = vpc.security_groups.filter('group-name', security_group_name).first
    unless security_group
      puts "Creating [#{security_group_name}] security group"
      security_group = vpc.security_groups.create security_group_name, :vpc => vpc
      revoke_all_permissions security_group # clean slate
      allow_https_egress security_group, ANYWHERE
      allow_http_egress security_group, ANYWHERE
      allow_ssh_ingress security_group, ANYWHERE
    end
    security_group
  end

  def revoke_all_permissions(security_group)
    revoke_all security_group.egress_ip_permissions
    revoke_all security_group.ingress_ip_permissions
  end

  def revoke_all(permissions)
    permissions.each { |permission| permission.revoke }
  end

  def allow_ssh_ingress(security_group, source)
    security_group.authorize_ingress :tcp, 22, source
  end

  def allow_http_egress(security_group, destination)
    security_group.authorize_egress destination, :protocol => :tcp, :ports => 80..80
  end

  def allow_https_egress(security_group, destination)
    security_group.authorize_egress destination, :protocol => :tcp, :ports => 443..443
  end

  def get_or_create_instance(ec2, name, image_id, instance_type, key_pair, security_group, subnet)
    instance = find_running_instance ec2, name
    unless instance
      puts "Creating [#{name}] instance"
      instance = ec2.instances.create(
          image_id: image_id,
          instance_type: instance_type,
          security_groups: security_group,
          key_pair: key_pair,
          subnet: subnet)
      wait_until_exists instance
      tag_with_name instance, name
      wait_until_status instance, :running
    end
    instance
  end

  def find_running_instance(root, name)
    find_running_instances(root).filter('tag:Name', name).first
  end

  def find_running_instances(root)
    root.instances.filter('instance-state-name', 'running')
  end

  def associate_elastic_ip(ec2, name, instance)
    elastic_ip = instance.elastic_ip
    unless elastic_ip
      elastic_ip = create_elastic_ip ec2
      instance.associate_elastic_ip elastic_ip
      puts "Instance [#{name}] has elastic ip [#{elastic_ip.public_ip}]"
    end
    elastic_ip.public_ip
  end

  def create_elastic_ip(ec2)
    elastic_ip = ec2.elastic_ips.find { |eip| !eip.associated? && eip.vpc? }
    unless elastic_ip
      puts "Creating a new elastic ip for vpc"
      elastic_ip = ec2.elastic_ips.create :vpc => true
    end
    elastic_ip
  end

  def find_tagged_with_name(coll, name)
    coll.tagged('Name').tagged_values(name).first
  end

  def tag_with_name(item, name)
    item.add_tag 'Name', value: name
  end

  def name_tag(item)
    item.tags['Name']
  end

  def connect_to_ec2
    ec2 = AWS::EC2.new(YAML.load_file(@credentials))
    ec2.regions[@config.region]
  end

  def connect_to_s3
    AWS::S3.new(YAML.load_file(@credentials))
  end

  def credentials?
    File.file? @credentials
  end

  def save_credentials(access_key_id, secret_access_key)
    credentials = {access_key_id: access_key_id, secret_access_key: secret_access_key}
    File.open(@credentials, 'w') { |out| YAML.dump credentials, out }
    File.chmod(0600, @credentials)
  end

  def wait_until_exists(item)
    sleep 1 until item.exists?
  end

  def wait_until_state(item, state)
    sleep 1 until item.state == state
  end

  def wait_until_status(item, status)
    sleep 1 while item.status != status
  end

  def delete_vpc
    ec2 = connect_to_ec2
    vpc = find_vpc ec2
    if vpc
      instances = []
      elastic_ips = []
      find_running_instances(vpc).each do |instance|
        instance_name = name_tag(instance) || 'Unnamed'
        puts "Terminating [#{instance.id} #{instance_name}] instance"
        elastic_ips << instance.elastic_ip if instance.has_elastic_ip?
        instances << instance
        instance.terminate
      end
      instances.each do |instance|
        puts "Waiting for [#{instance.id}] to terminate"
        wait_until_status instance, :terminated
      end
      elastic_ips.each do |elastic_ip|
        if elastic_ip.associated?
          "Disassociating [#{elastic_ip.public_ip}] elastic ip"
          elastic_ip.disassociate
        end
      end
      elastic_ips.each do |elastic_ip|
        puts "Deleting [#{elastic_ip.public_ip}] elastic ip"
        elastic_ip.delete
      end
      security_groups = []
      vpc.security_groups.each do |security_group|
        puts "Clearing out permissions for [#{security_group.name}] security group"
        revoke_all_permissions security_group
        security_groups << security_group
      end
      sleep 5 # takes time to revoke permissions
      security_groups.each do |security_group|
        unless security_group.name == 'default'
          puts "Deleting [#{security_group.name}] security group"
          security_group.delete
        end
      end
      vpc.subnets.each do |subnet|
        puts "Deleting [#{subnet.id} #{name_tag(subnet)}] subnet"
        subnet.delete
      end
      vpc.route_tables.each do |route_table|
        unless route_table.main?
          puts "Deleting [#{route_table.id} #{name_tag(route_table)}] route table"
          route_table.delete
        end
      end
      gateway = vpc.internet_gateway
      if gateway
        puts "Deleting [#{gateway.id} #{name_tag(gateway)}] internet gateway"
        vpc.internet_gateway = nil
        gateway.delete
      end
      puts "Deleting [#{vpc.id} #{name_tag(vpc)}] vpc"
      vpc.delete
    end
  end

end
