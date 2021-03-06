require 'daemon_controller'

module TestDaemons
  class RedisConfigurationServer

    # At the moment, we need only one, so we implement the methods
    # as class methods

    @@redis_servers = ""
    @@redis_configuration_clients = ""

    def self.start(redis_servers, redis_configuration_clients)
      stop
      @@redis_servers = redis_servers
      @@redis_configuration_clients = redis_configuration_clients
      daemon_controller.start
    end

    def self.stop
      daemon_controller.stop
    end

    def self.daemon_controller
      clients_parameter_string = @@redis_configuration_clients.blank? ? "" : "--client-ids #{@@redis_configuration_clients}"
      DaemonController.new(
         :identifier    => "Redis configuration test server",
         :start_command => "ruby bin/beetle configuration_server start -- -v --redis-master-file #{redis_master_file} --redis-servers #{@@redis_servers} #{clients_parameter_string} --redis-retry-interval 1 --pid-dir #{tmp_path} --amqp-servers 127.0.0.1:5672",
         :ping_command  => lambda{ true },
         :pid_file      => pid_file,
         :log_file      => log_file,
         :start_timeout => 5
      )
    end

    def self.redis_master_file
      "#{tmp_path}/redis-master-rc-server"
    end

    def self.pid_file
      "#{tmp_path}/redis_configuration_server.pid"
    end

    def self.log_file
      "#{tmp_path}/redis_configuration_server.output"
    end

    def self.tmp_path
      File.expand_path(File.dirname(__FILE__) + "/../../../tmp")
    end

  end
end
