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

group :test do
  gem 'jdbc-mysql', :require => nil, :platform => :jruby
  gem 'jdbc-postgres', :require => nil, :platform => :jruby
  gem 'jdbc-sqlite3', :require => nil, :platform => :jruby

  gem 'mysql2', :require => nil, :platform => :mri
  gem 'pg', :require => nil, :platform => :mri
end
