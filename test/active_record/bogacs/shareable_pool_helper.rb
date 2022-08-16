
require File.expand_path('../../test_helper', File.dirname(__FILE__))

ActiveRecord::Bogacs::ShareablePool.class_eval do
  attr_reader :shared_connections
  attr_writer :size, :shared_size
end

module ActiveRecord
  module Bogacs
    class ShareablePool

      module TestHelpers

        def teardown; connection_pool.disconnect! end

        def connection_pool
          ActiveRecord::Base.connection_pool
        end

        def initialized_connections
          ActiveRecord::Base.connection_pool.connections.dup
        end
        alias_method :connections, :initialized_connections

        def reserved_connections
          connection_pool.instance_variable_get :@thread_cached_conns
        end

        def available_connections
          connection_pool.available.instance_variable_get(:'@queue').dup
        end

        def available_connection? connection
          available_connections.include? connection
        end

        def shared_connections
          ActiveRecord::Base.connection_pool.shared_connections
        end

        def shared_connection? connection
          !!shared_connections.get(connection)
        end

        def with_shared_connection(&block)
          ActiveRecord::Base.connection_pool.with_shared_connection(&block)
        end

        def clear_active_connections!
          ActiveRecord::Base.clear_active_connections!
        end

        def clear_shared_connections!
          connection_pool = ActiveRecord::Base.connection_pool
          shared_connections.keys.each do |connection|
            connection_pool.release_shared_connection(connection)
          end
        end

      end

      class TestBase < ::Test::Unit::TestCase
        include TestHelpers

        def self.startup
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ShareablePool

          ActiveRecord::Base.establish_connection AR_CONFIG
        end

        def self.shutdown
          ActiveRecord::Base.connection_pool.disconnect!
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ConnectionAdapters::ConnectionPool
        end

      end

    end
  end
end
