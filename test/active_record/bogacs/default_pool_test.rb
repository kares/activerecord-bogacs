require File.expand_path('../../test_helper', File.dirname(__FILE__))

ActiveRecord::Bogacs::DefaultPool.class_eval do
  # ...
end

module ActiveRecord
  module Bogacs
    class DefaultPoolTest < Test::Unit::TestCase

      include ConnectionAdapters::ConnectionPoolTestMethods

      def config; AR_CONFIG end

      def setup
        super
        @pool = DefaultPool.new ActiveRecord::Base.connection_pool.spec
      end

      def test_prefills_initial_connections
        @pool.disconnect!
        spec = ActiveRecord::Base.connection_pool.spec.dup
        spec.instance_variable_set :@config, spec.config.merge(:pool_initial => 1.0)
        @pool = DefaultPool.new spec
        assert_equal @pool.size, @pool.connections.size
      end

      def test_does_not_prefill_connections_by_default
        assert_equal 0, @pool.connections.size
      end

      def test_connection_removed_connection_on_checkout_failure
        connection = nil

        Thread.new {
          pool.with_connection do |conn|
            connection = conn
          end
        }.join

        assert connection
        assert_equal 1, pool.connections.size

        bad_connection = connection
        def bad_connection.verify!
          raise ThreadError, 'corrupted-connection'
        end

        begin
          connection = pool.connection
        rescue ThreadError
        else; warn 'verify! error not raised'
        end
        assert_equal 0, pool.connections.size # gets removed from pool

        connection = pool.connection
        assert bad_connection != connection, 'bad connection returned on checkout'

      end if ActiveRecord::VERSION::STRING > '4.2'

      def self.startup; puts "running with ActiveRecord: #{ActiveRecord::VERSION::STRING}" end

    end
  end
end