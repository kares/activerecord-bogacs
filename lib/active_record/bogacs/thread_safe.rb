module ActiveRecord
  module Bogacs
    module ThreadSafe

      require 'concurrent/map.rb'
      Map = ::Concurrent::Map

      autoload :Synchronized, 'active_record/bogacs/thread_safe/synchronized'

      def self.load_cheap_lockable(required = true)
        return const_get :CheapLockable if const_defined? :CheapLockable

        begin
          require 'concurrent/thread_safe/util/cheap_lockable.rb'
        rescue LoadError => e
          begin
            require 'thread_safe'
          rescue
            return nil unless required
            warn "activerecord-bogacs needs gem 'concurrent-ruby', '~> 1.0' (or the old 'thread_safe' gem)" +
                 " please install or add it to your Gemfile"
            raise e
          end
        end

        if defined? ::Concurrent::ThreadSafe::Util::CheapLockable
          const_set :CheapLockable, ::Concurrent::ThreadSafe::Util::CheapLockable
        else
          const_set :CheapLockable, ::ThreadSafe::Util::CheapLockable
        end
      end

    end
  end
end
