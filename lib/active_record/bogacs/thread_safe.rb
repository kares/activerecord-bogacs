module ActiveRecord
  module Bogacs
    module ThreadSafe

      def self.load_map
        begin
          require 'concurrent/map.rb'
        rescue LoadError => e
          begin
            require 'thread_safe'
          rescue
            warn "activerecord-bogacs needs gem 'concurrent-ruby', '~> 1.0' (or the old 'thread_safe' gem) " <<
                 "please install or add it to your Gemfile"
            raise e
          end
        end
      end

      load_map # always pre-load thread_safe

      if defined? ::Concurrent::Map
        Map = ::Concurrent::Map
      else
        Map = ::ThreadSafe::Cache
      end

      autoload :Synchronized, 'active_record/bogacs/thread_safe/synchronized'

      def self.load_atomic
        return if const_defined? :AtomicReference

        begin
          require 'concurrent/atomic/atomic_reference.rb'
        rescue LoadError => e
          begin
            require 'atomic'
          rescue LoadError
            warn "shareable pool needs gem 'concurrent-ruby', '>= 0.9.1' (or the old 'atomic' gem) " <<
                 "please install or add it to your Gemfile"
            raise e
          end
        end

        if defined? ::Concurrent::AtomicReference
          const_set :AtomicReference, ::Concurrent::AtomicReference
        else
          const_set :AtomicReference, ::Atomic
        end
      end

    end
  end
end