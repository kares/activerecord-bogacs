require 'active_record'
require 'active_record/version'
require 'active_record/connection_adapters/abstract/connection_pool'

# NOTE: needs explicit configuration - before connection gets established e.g.
#
#   klass = ActiveRecord::Bogacs::FalsePool
#   ActiveRecord::ConnectionAdapters::ConnectionHandler.connection_pool_class = klass
#
module ActiveRecord
  module ConnectionAdapters
    # @private there's no other way to change the pool class to use but to patch :(
    ConnectionHandler.class_eval do

      @@connection_pool_class = ConnectionAdapters::ConnectionPool

      def connection_pool_class; @@connection_pool_class end
      def self.connection_pool_class=(klass); @@connection_pool_class = klass end

      if ActiveRecord::VERSION::MAJOR > 3 # 4.x

        def establish_connection(owner, spec)
          @class_to_pool.clear
          owner_to_pool[owner.name] = connection_pool_class.new(spec)
        end

      elsif ActiveRecord::VERSION::MAJOR == 3 && ActiveRecord::VERSION::MINOR == 2

        def establish_connection(name, spec)
          @class_to_pool[name] =
            ( @connection_pools[spec] ||= connection_pool_class.new(spec) )
        end

      else # 2.3/3.0/3.1

        def establish_connection(name, spec)
          @connection_pools[name] = connection_pool_class.new(spec)
        end

      end

    end
  end
end
