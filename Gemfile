source 'https://rubygems.org'

gemspec

if version = ENV['AR_VERSION']
  if version.index('/') && ::File.exist?(version)
    gem 'activerecord', :path => version
  elsif version =~ /^[0-9abcdef]+$/
    gem 'activerecord', :github => 'rails/rails', :ref => version
  elsif version.index('.').nil?
    gem 'activerecord', :github => 'rails/rails', :branch => version
  else
    gem 'activerecord', version, :require => nil
  end
else
  gem 'activerecord', :require => nil
end

if RUBY_VERSION.index('1.8') == 0
  gem 'i18n', '< 0.7.0' # Gem::InstallError: i18n requires Ruby version >= 1.9.3
  gem 'atomic', '1.1.16' # concurrent-ruby gem only for Ruby version >= 1.9.3
  gem 'thread_safe', '~> 0.3'
else
  gem 'concurrent-ruby', '1.0.0.pre4', :require => nil
end

platform :jruby do
  if version = ENV['AR_JDBC_VERSION']
    if version.index('/') && ::File.exist?(version)
      gem 'activerecord-jdbc-adapter', :path => version
    elsif version =~ /^[0-9abcdef]+$/
      gem 'activerecord-jdbc-adapter', :github => 'jruby/activerecord-jdbc-adapter', :ref => version
    elsif version.index('.').nil?
      gem 'activerecord-jdbc-adapter', :github => 'jruby/activerecord-jdbc-adapter', :branch => version
    else
      gem 'activerecord-jdbc-adapter', version, :require => nil
    end
  else
    gem 'activerecord-jdbc-adapter', :require => nil
  end
end

#gem 'thread_safe', :require => nil # "optional" - we can roll without it

if defined?(JRUBY_VERSION) && JRUBY_VERSION < '1.7.0'
gem 'jruby-openssl', :platform => :jruby
end

group :test do
  gem 'jdbc-mysql', :require => nil, :platform => :jruby
  gem 'jdbc-postgres', :require => nil, :platform => :jruby

  gem 'mysql2', :require => nil, :platform => :mri
  gem 'pg', :require => nil, :platform => :mri
end