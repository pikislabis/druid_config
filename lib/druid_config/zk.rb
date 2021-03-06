#
# This Class is an adaptation from ZK Class of ruby-druid gem.
# Please, check the following link:
#   https://github.com/ruby-druid/ruby-druid/blob/master/lib/druid/zk.rb
#

require 'zk'
require 'rest_client'

module DruidConfig
  #
  # Class to connect and get information about nodes in cluster using
  # Zookeeper
  #
  class ZK
    # Coordinator service
    COORDINATOR = 'coordinator'
    OVERLORD = 'overlord'
    SERVICES = [COORDINATOR, OVERLORD]

    #
    # Initialize variables and call register
    #
    # == Parameters:
    # uri::
    #   Uri of zookeper
    # opts::
    #   Hash with options:
    #     - discovery_path: Custom URL of discovery path for Druid
    #
    def initialize(uri, opts = {})
      # Control Zookeper connection
      @zk = ::ZK.new(uri, chroot: :check)
      @registry = Hash.new { |hash, key| hash[key] = [] }
      @discovery_path = opts[:discovery_path] || '/discovery'
      @watched_services = {}
      @verify_retry = 0
      register
    end

    #
    # Load the data from Zookeeper
    #
    def register
      $log.info('druid.zk register discovery path') if $log
      @zk.on_expired_session { register }
      @zk.register(@discovery_path, only: :child) do
        $log.info('druid.zk got event on discovery path') if $log
        check_services
      end
      check_services
    end

    #
    # Force to close Zookeper connection
    #
    def close!
      $log.info('druid.zk shutting down') if $log
      @zk.close!
    end

    #
    # Return the URI of a random available coordinator.
    # Poor mans load balancing
    #
    def coordinator
      random_node(COORDINATOR)
    end

    #
    # Return the URI of a random available overlord.
    # Poor mans load balancing
    #
    def overlord
      random_node(OVERLORD)
    end

    #
    # Return a random value of a service
    #
    # == Parameters:
    # service::
    #   String with the name of the service
    #
    def random_node(service)
      return nil if @registry[service].size == 0
      # Return a random broker from available brokers
      @registry[service].sample[:uri]
    end

    #
    # Register a new service
    #
    def register_service(service, brokers)
      $log.info("druid.zk register", service: service, brokers: brokers) if $log
      # poor mans load balancing
      @registry[service] = brokers
    end

    #
    # Unregister a service
    #
    def unregister_service(service)
      $log.info("druid.zk unregister", service: service) if $log
      @registry.delete(service)
      unwatch_service(service)
    end

    #
    # Set a watcher for a service
    #
    def watch_service(service)
      return if @watched_services.include?(service)
      $log.info("druid.zk watch", service: service) if $log
      watch = @zk.register(watch_path(service), only: :child) do |event|
        $log.info("druid.zk got event on watch path for", service: service, event: event) if $log
        unwatch_service(service)
        check_service(service)
      end
      @watched_services[service] = watch
    end

    #
    # Unset a service to watch
    #
    def unwatch_service(service)
      return unless @watched_services.include?(service)
      $log.info("druid.zk unwatch", service: service) if $log
      @watched_services.delete(service).unregister
    end

    #
    # Check current services
    #
    def check_services
      $log.info("druid.zk checking services") if $log
      zk_services = @zk.children(@discovery_path, watch: true)

      (services - zk_services).each do |service|
        unregister_service(service)
      end

      zk_services.each do |service|
        check_service(service)
      end
    end

    #
    # Verify is a Coordinator is available. To do check, this method perform a
    # GET request to the /status end point. This method will retry to connect
    # three times with a delay of 0.8, 1.6, 2.4 seconds.
    #
    # == Parameters:
    # name::
    #   String with the name of the coordinator
    # service::
    #   String with the service
    #
    # == Returns:
    # URI of the coordinator or false
    #
    def verify_node(name, service)
      $log.info("druid.zk verify", node: name, service: service) if $log
      info = @zk.get("#{watch_path(service)}/#{name}")
      node = JSON.parse(info[0])
      uri = "http://#{node['address']}:#{node['port']}/"
      # Try to get /status
      check = RestClient::Request.execute(
        method: :get, url: "#{uri}status",
        timeout: 5, open_timeout: 5
      )
      $log.info("druid.zk verified", uri: uri, sources: check) if $log
      return uri if check.code == 200
    rescue
      return false unless @verify_retry < 3
      # Sleep some time and retry
      @verify_retry += 1
      sleep 0.8 * @verify_retry
      retry
    ensure
      # Reset verify retries
      @verify_retry = 0
    end

    #
    # Return the path of a service in Zookeeper.
    #
    # == Parameters:
    # service::
    #   String with the name of the service
    #
    def watch_path(service)
      "#{@discovery_path}/#{service}"
    end

    #
    # Check a given Druid service. Now we only need to track coordinator and
    # overlord services. This method create a watcher to the service to check
    # changes.
    #
    # This method get the available nodes in the Zookeeper path. When return
    # them, it tries to connect to /status end point to check if the node
    # is available. After it, it store in @registry.
    #
    # == Parameters:
    # service::
    #   String with the service to check
    #
    def check_service(service)
      # Only watch some services
      return if @watched_services.include?(service) ||
                !SERVICES.include?(service)
      # Start to watch this service
      watch_service(service)
      # New list of nodes
      new_list = []

      # Verify every node
      live = @zk.children(watch_path(service), watch: true)
      live.each do |name|
        # Verify a node
        uri = verify_node(name, service)
        # If != false store the URI
        new_list.push(name: name, uri: uri) if uri
      end
      # Register new service in the registry
      register_service(service, new_list)
    end

    #
    # Get all available services
    #
    def services
      @registry.keys
    end

    def to_s
      @registry.to_s
    end
  end
end
