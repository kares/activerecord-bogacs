require 'active_record/version'

require 'active_record/connection_adapters/abstract/connection_pool'

module ActiveRecord
  module Bogacs
    class ConnectionHandler < ConnectionAdapters::ConnectionHandler

      if ActiveRecord::VERSION::MAJOR < 5

        def establish_connection(owner, spec)
          @class_to_pool.clear
          if spec.config[:pool].eql? false
            owner_to_pool[owner.name] = ActiveRecord::Bogacs::FalsePool.new(spec)
          else # super
            owner_to_pool[owner.name] = ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec)
          end
        end

      else

        def establish_connection(config) # (spec) in 5.0
          pool = super
          spec = pool.spec
          if spec.config[:pool].eql? false
            owner_to_pool[owner.name] = ActiveRecord::Bogacs::FalsePool.new(spec)
          else
            pool
          end
        end

      end

    end
  end
end