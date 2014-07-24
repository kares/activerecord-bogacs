require File.expand_path('../../test_helper', File.dirname(__FILE__))

ActiveRecord::Bogacs::FalsePool.class_eval do
  # ...
end

module ActiveRecord
  module Bogacs
    class FalsePool

      class TestBase < ::Test::Unit::TestCase
        # extend Bogacs::TestHelper
        extend Bogacs::JndiTestHelper

        def self.startup
          return if self == TestBase

          ActiveRecord::Base.establish_connection AR_CONFIG

          ActiveRecord::Base.connection.jdbc_connection # force connection
          current_config = Bogacs::TestHelper.current_connection_config

          ActiveRecord::Base.connection_pool.disconnect!

          setup_jdbc_context
          bind_data_source init_data_source current_config

          ConnectionAdapters::ConnectionHandler.connection_pool_class = FalsePool
          ActiveRecord::Base.establish_connection jndi_config
        end

        def self.shutdown
          return if self == TestBase

          ActiveRecord::Base.connection_pool.disconnect!
          ConnectionAdapters::ConnectionHandler.connection_pool_class = ConnectionAdapters::ConnectionPool
        end

      end

      class ConnectionPoolWrappingTomcatJdbcTest < TestBase

        include ConnectionAdapters::ConnectionPoolTestMethods

        undef :test_checkout_fairness
        undef :test_checkout_fairness_by_group

        undef :test_released_connection_moves_between_threads

        def self.init_data_source(config); init_tomcat_jdbc_data_source(config) end

        def setup
          @pool = FalsePool.new ActiveRecord::Base.connection_pool.spec
        end

        def test_uses_false_pool_and_can_execute_query
          assert_instance_of ActiveRecord::Bogacs::FalsePool, ActiveRecord::Base.connection_pool
          assert ActiveRecord::Base.connection.exec_query('SELECT 42')
        end

      end

    end
  end
end