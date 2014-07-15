#!/usr/bin/env ruby

require 'optparse'
require 'base64'
require 'yaml'
require 'bundler/setup'
Bundler.require

COREOS_AWS_ID = '595879546273'

class Configuration
  def initialize(argv=ARGV)
    @config = {
      count: 3,
      verbose: false,
      instance_type: 't1.micro',
    }
    optparser.parse!(argv)
    validate_options!
  end

  def discovery_url
    @discovery_url ||= @config.fetch(:discovery_url) { new_discovery_url }
  end

  def user_data
    userdata_from_cloudinit_data(cloudinit)
  end

  def regions
    @regions ||= @config.fetch(:regions).map { |r| Region.new(r) }
  end

  def instance_type
    @config.fetch(:instance_type)
  end

  def keypair_name
    @config.fetch(:keypair_name)
  end

  def count
    @config.fetch(:count)
  end

  private

  def validate_options!
    unless @config.key?(:cloudinit) && @config.key?(:regions) && @config.key?(:keypair_name)
      warn optparser.help
      exit 1
    end
  end

  def optparser
    @optparser ||= OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options]"

      opts.on("--cloudinit FILE", "[Required] Path to file cloudinit.yml file to configure CoreOS boot") do |f|
        @config[:cloudinit] = parse_and_validate_cloudinit_file(f)
      end
      opts.on("--regions REGION[,REGION...]", "[Required] Comma-delimited list of AWS regions to launch in") do |f|
        @config[:regions] = f.split(',').map(&:strip)
      end
      opts.on("--keypair-name NAME", "[Required]: Name of the keypair to install (must exist by this name across all regions)") do |v|
        @config[:keypair_name] = v
      end
      opts.on("--count NUM", "Total quantity of instances to create (defaults to 3)") do |v|
        @config[:count] = v.to_i
      end
      opts.on("--discovery URL", "Discovery URL if not in the cloudinit already (creates a new one by default)") do |v|
        @config[:discovery_url] = URL.parse(v).to_s
      end
      opts.on("--instance-type TYPE", "Instance type (defaults to t1.micro)") do |v|
        @config[:instance_type] = v
      end
      opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
        @config[:verbose] = v
      end
    end
  end

  def parse_and_validate_cloudinit_file(path)
    raise "Can't read cloudinit file: #{path}" unless File.readable?(path)

    contents = File.read(path)

    unless contents =~ /\A#cloud-config\n/
      raise "Must have the '#cloud-config' label as a comment on the first line"
    end

    YAML.load(contents)
  end

  def new_discovery_url
    open('https://discovery.etcd.io/new').read.strip
  end

  def add_etcd_data_to_cloudinit(cloudinit)
    coreos = cloudinit['coreos'] ||= {}
    etcd = coreos['etcd'] ||= {}
    etcd['discovery'] ||= discovery_url
    etcd['addr'] ||= '$public_ipv4:4001'
    etcd['peer-addr'] ||= '$public_ipv4:7001'
    cloudinit
  end

  def userdata_from_cloudinit_data(cloudinit)
    string = "#cloud-config\n\n"
    string << cloudinit.to_yaml
    Base64.encode64(string)
  end

  def cloudinit
    @cloudinit ||= add_etcd_data_to_cloudinit(@config[:cloudinit])
  end
end

class Region
  SECURITY_GROUP_NAME = 'CoreOS-multi-region-cluster-INSECURE'

  def initialize(name)
    @name = name
    @ec2 = Aws::EC2::Client.new(region: @name)
  end
  attr_reader :ec2, :name

  def use_ami(ami)
    @ami_id = ami.image_id
  end

  def ami_id
    raise "AMI not set" unless @ami_id
    @ami_id
  end

  def security_group
    return @security_group if defined?(@security_group)
    results = ec2.describe_security_groups(
      filters: [
        { name: 'group-name', values: [SECURITY_GROUP_NAME] }
      ]
    ).security_groups

    if existing = results.first
      log "Using security group '#{existing.group_name}' (#{existing.group_id})"
      @security_group ||= existing.group_id
    else
      @security_group ||= create_security_group
    end
  end

  def register_instances(i)
    instances.concat(i)
    i
  end

  def instances
    @instances ||= []
  end

  def launch_instance(options)
    log "Launching instance"
    result = ec2.run_instances(
      # dry_run: true,
      image_id: ami_id,
      min_count: 1,
      max_count: 1,
      key_name: options.fetch(:keypair_name),
      security_group_ids: [security_group],
      user_data: options.fetch(:user_data),
      instance_type: options.fetch(:instance_type)
    )
    register_instances(result.instances).each do |instance|
      log "Created new instance #{instance.instance_id}"
    end
  end

  def terminate_instance(instance_id)
    log "Terminating #{instance_id}"
    ec2.terminate_instances(instance_ids: Array(instance_id))
  end

  def find_ami(coreos_version)
    result = ec2.describe_images(filters: [
      { name: 'name', values: ['CoreOS-alpha-*', "*-#{coreos_version}-*"] },
      { name: 'owner-id', values: [COREOS_AWS_ID] },
      { name: 'virtualization-type', values: ['paravirtual'] },
    ])
    return nil if result.images.count == 0
    return result.images.sort_by(&:name).last
  end

  private

  def create_security_group
    log "Creating a new security group named '#{SECURITY_GROUP_NAME}'"
    group_id = ec2.create_security_group(
      group_name: SECURITY_GROUP_NAME,
      description: "Automatically generated group for INSECURE CoreOS cluster access across multiple regions"
    ).group_id

    log "Adding ingress rules to new security group '#{SECURITY_GROUP_NAME}' (#{group_id})"
    ec2.authorize_security_group_ingress(
      group_id: group_id,
      ip_permissions: [
        {
          ip_protocol: 'tcp',
          from_port: 4001,
          to_port: 4001,
          ip_ranges: [{ cidr_ip: '0.0.0.0/0' }],
        },
        {
          ip_protocol: 'tcp',
          from_port: 7001,
          to_port: 7001,
          ip_ranges: [{ cidr_ip: '0.0.0.0/0' }],
        },
        {
          ip_protocol: 'tcp',
          from_port: 22,
          to_port: 22,
          ip_ranges: [{ cidr_ip: '0.0.0.0/0' }],
        },
      ],
    )

    group_id
  end

  def log(message)
    warn "[#{@name}] #{message}"
  end
end

class Converger
  def initialize(config)
    @config = config
  end

  def determine_release_and_set_ami_ids
    return if @found_amis
    puts "Looking up AMIs for latest CoreOS release"
    recent_releases.each do |tag|
      matches = regions.inject({}) do |hash, region|
        hash[region] = region.find_ami(tag)
        hash
      end
      next if matches.values.any?(&:nil?)

      puts "Found the following AMIs for CoreOS release #{tag}:"
      matches.each do |region, ami|
        puts " %15s - %-14s %s" % [region.name, ami.image_id, ami.name]
        region.use_ami(ami)
      end

      @found_amis = true
      return
    end
    raise "Couldn't find a suitable AMI for the releases found: #{recent_releases.join(', ')}"
  end

  def launch_all_instances
    regionumerator = regions.cycle
    @config.count.times do
      regionumerator.next.launch_instance(
        user_data: @config.user_data,
        instance_type: @config.instance_type,
        keypair_name: @config.keypair_name
      )
    end
  end

  def each_instance
    regions.each do |region|
      region.instances.each do |instance|
        yield instance, region
      end
    end
  end

  def terminate_all_instances
    each_instance do |i, region|
      region.terminate_instance(i.instance_id)
    end
  end

  private

  def regions
    @config.regions
  end

  def recent_releases
    return @recent_releases if defined?(@recent_releases)

    puts "Asking Github for list of latest CoreOS releases"
    @recent_releases ||= Octokit.releases('coreos/manifest').map { |r|
      r.tag_name.sub(/^v/, '')
    }
  end
end

config = Configuration.new(ARGV)

thing = Converger.new(config)
# thing.determine_release_and_set_ami_ids

# thing.launch_all_instances

binding.pry
