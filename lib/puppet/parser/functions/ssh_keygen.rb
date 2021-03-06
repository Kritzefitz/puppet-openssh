# Forked from htratps://github.com/fup/puppet-ssh @ 59684a8ae174
#
# Takes a Hash of config arguments:
#   Required parameters:
#     :name   (the name of the key - e.g 'my_ssh_key')
#     :request (what type of return value is requested (public, private, auth, known)
#
#   Optional parameters:
#     :type    (the key type - default: 'rsa')
#     :dir     (the subdir of /etc/puppet/ to store the key in - default: 'ssh')
#     :hostkey (weither the key should be a hostkey or not. defines weither to add it to known_hosts or not)
#     :hostaliases (specify aliases for the host for whom a hostkey is created (will be added to known_hosts))
#     :authkey (weither the key is an authkey or not. defines weither to add it to authorized_keys or not)
#     :as_hash (weither to return authorized_keys as list of hashes (only for request authorized keys))
#
require 'fileutils'




def get_known_hosts(fullpath)
    known_hosts = "#{fullpath}/known_hosts"
    return File.open(known_hosts).read
end

def get_authorized_keys(fullpath, as_hash = false)
    known_hosts = "#{fullpath}/authorized_keys"

    # short-circuit requests for authorized_keys before first keys have been created
    unless File.exists?(known_hosts)
      return (as_hash) ? {} : ""
    end

    unless as_hash
        return File.open(known_hosts).read
    end

    result = {}
    File.foreach(known_hosts) do |line|
        next if line =~ /^#/
        next if line =~ /^$/

        (type, key, comment) = line.split(' ')


        result[comment] = {
                'type'      => type,
                'key'       => key,
                'name'   => comment
        }
    end

    return result
end


class SSHKeyGen
    # stores the name of the ssh key
    attr_reader :name

    # cache dir
    attr_reader :cache_dir

    # key attributes
    attr_reader :key_type
    attr_reader :key_comment
    attr_reader :key_options

    attr_reader :facts

    def initialize(name, type, comment, options = {})
        @name           = name
        @cache_dir      = options[:cache_dir]
        @facts          = options[:facts]
        @key_type       = type
        @key_options    = options
        @key_comment    = comment
    end

    def generate_keypair
        keyfile = filename_for(:private_key)

        unless File.exists?(keyfile)
            cmdline = "/usr/bin/ssh-keygen -q -t #{key_type} -N '' -C '#{key_comment}' -f #{keyfile}"
            output = %x[#{cmdline}]
            if $?.exitstatus != 0
                raise Puppet::ParseError, "calling '#{cmdline}' resulted in error: #{output}"
            end

            if key_options[:authkey]
                add_key_to_authorized_keys(cache_dir, name, keyfile)
            end

            if key_options[:hostkey]
                add_to_known_hosts
            end
        end
    end

    def add_to_known_hosts
        known_hosts = "#{cache_dir}/known_hosts"
        if not File.exists?(known_hosts)
            File.open(known_hosts, 'w') { |f| f.write "# managed by puppet\n" }
        end

        if not facts['fqdn']
            raise Puppet::ParseError, "unable to determine fqdn: please check system configuration"
        end


        hosts = "#{facts['hostname']},#{facts['fqdn']},#{facts['ipaddress']}"
        unless key_options[:hostaliases].nil? or key_options[:hostaliases] == :undef
            hosts = hosts + "," + key_options[:hostaliases].join(",")
        end

        key             = public_key()
        search_string   = "^.* " + Regexp.escape(key) + "$"

        lines = File.open(known_hosts).readlines

        unless File.open(known_hosts).readlines.grep(/#{search_string}/).size > 0
            line = "#{hosts} #{key}"
            File.open(known_hosts, 'a') { |file| file.write(line) }
        end
    end

    def add_key_to_authorized_keys(fullpath, name, keyfile)
        authorized_keys = "#{fullpath}/authorized_keys"
        if not File.exists?(authorized_keys)
            File.open(authorized_keys, 'w') { |f| f.write "# managed by puppet\n" }
        end

        File.open(authorized_keys, 'a') { |file| file.write(public_key().to_s) }
    end

    def filename_for(key_type = :private_key)
        if key_type == :public_key
            filename = name + '.pub'
        elsif key_type == :certificate
            filename = name + '-cert.pub'
        else
            filename = name
        end

        return File.join(cache_dir, filename)
    end


    def keyfile_contents(key_type = :private_key)
        keyfile = filename_for(key_type)

        unless File.exists?(keyfile)
            generate_keypair(key_type)
        end

        begin
            return File.open(keyfile).read
        rescue => e
            raise Puppet::ParseError, "ssh_keygen(): unable to read file `#{keyfile}': #{e}"
        end
    end

    def private_key
        @private_key ||= keyfile_contents(key_type = :private_key)
    end

    def public_key
        @public_key ||= keyfile_contents(key_type = :public_key)
    end
end

module Puppet::Parser::Functions
  newfunction(:ssh_keygen, :type => :rvalue) do |args|
    unless args.first.class == Hash then
      raise Puppet::ParseError, "ssh_keygen(): config argument must be a Hash"
    end

    config = args.first

    config = {
      'request'                 => nil,
      'basedir'                 => '/etc/puppet',
      'dir'                     => 'ssh',

      'type'                    => 'rsa',
      'hostkey'                 => false,
      'hostaliases'             => nil,
      'authkey'                 => false,
      'comment'                 => nil,

      'as_hash'                 => false,
    }.merge(config)

    if config['request'].nil?
        raise Puppet::ParseError, "ssh_keygen(): request argument is required"
    end

    request = config['request']
    if config['name'].nil? and (request != 'authorized_keys' and request != 'known_hosts')
        raise Puppet::ParseError, "ssh_keygen(): name argument is required"
    end

    # construct fullpath from puppet base and dir argument
    fullpath = "#{config['basedir']}/#{config['dir']}"
    if File.exists?(fullpath) and not File.directory?(fullpath)
        raise Puppet::ParseError, "ssh_keygen(): #{fullpath} exists but is not directory"
    end
    unless File.exists?(fullpath)
        FileUtils.mkdir_p fullpath
    end

    if request == 'authorized_keys'
        return get_authorized_keys(fullpath, as_hash=config['as_hash'])
    end

    if request == 'known_hosts'
        return get_known_hosts(fullpath)
    end

    facts = Hash.new
    %w{ hostname fqdn ipaddress }.each { |var| facts[var] = lookupvar(var) }

    # Let comment default to something sensible, unless the user really
    # wants to set it to ''(then we don't stop him)
    if config['comment'].nil?
        hostname = lookupvar('hostname')
        if config['hostkey'] == true
            config['comment'] = hostname
        elsif config['authkey'] == true
            config['comment'] = "root@#{hostname}"
        end
    end

    keypair = SSHKeyGen.new(config['name'], config['type'], config['comment'], {
        :cache_dir      => fullpath,
        :facts          => facts,
        :hostaliases    => config['hostaliases'],
        :authkey        => config['authkey'],
        :hostkey        => config['hostkey']
    })

    keypair.generate_keypair()

    # Check what mode of action is requested
    begin
        case request
        when "public"
            return keypair.public_key()
        when "private"
            return keypair.private_key()
        when "known_hosts"
            return get_known_hosts(fullpath)
        when "authorized_keys"
            return get_authorized_keys(fullpath, config['as_hash'])
        end
    rescue => e
        raise Puppet::ParseError, "ssh_keygen(): unable to fulfill request '#{config['request']}': #{e}"
    end
  end
end
