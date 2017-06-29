require File.expand_path('../boot', __FILE__)

require 'rails/all'

# Require core functionalities
require File.expand_path('../../lib/core', __FILE__)

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module MonsoonDashboard
  class Application < Rails::Application
    config.react.addons = true

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    #config.autoload_paths += %W(#{config.root}/plugins)
    config.autoload_paths << Rails.root.join('lib')

    # Use memory for caching, file cache needs some work for working with docker
    # Not sure if this really makes sense becasue every passenger thread will have it's own cache
    config.cache_store = :memory_store

    # Set Time.zone default to the specified zone and make Active Record auto-convert to this zone.
    # Run "rake -D time" for a list of tasks for finding time zone names. Default is UTC.
    # config.time_zone = 'Central Time (US & Canada)'

    # The default locale is :en and all translations from config/locales/*.rb,yml are auto loaded.
    # config.i18n.load_path += Dir[Rails.root.join('my', 'locales', '*.{rb,yml}').to_s]
    # config.i18n.default_locale = :de

    # Do not swallow errors in after_commit/after_rollback callbacks.
    config.active_record.raise_in_transactional_callbacks = true

    config.middleware.insert_before Rack::Sendfile, "DebugHeadersMiddleware"

    require 'prometheus/client/rack/collector'

    # build a map from the plugins
    plugin_mount_points = {}
    Core::PluginsManager.available_plugins.each{|plugin| plugin_mount_points[plugin.mount_point] = plugin.mount_point}

    config.middleware.insert_after ActionDispatch::DebugExceptions, Prometheus::Client::Rack::Collector do |env|
      {
        method: env['REQUEST_METHOD'].downcase,
        host:   env['HTTP_HOST'].to_s,
        # just take the first component of the path as a label
        path:   env['REQUEST_PATH'][0, env['REQUEST_PATH'].index('/',1) || 20 ],
        controller: env.fetch("action_dispatch.request.path_parameters",{}).fetch(:controller,''),
        action: env.fetch("action_dispatch.request.path_parameters",{}).fetch(:action,''),
        plugin: if env.fetch("action_dispatch.request.path_parameters",{}).fetch(:project_id,false)
          plugin_mount_points[env['REQUEST_PATH'].split("/")[3]] || ""
        elsif env.fetch("action_dispatch.request.path_parameters",{}).fetch(:domain_id, false)
          plugin_mount_points[env['REQUEST_PATH'].split("/")[2]] || ""
        else
          ''
        end
      }
    end

    require 'prometheus/client/rack/exporter'
    config.middleware.insert_after  Prometheus::Client::Rack::Collector, Prometheus::Client::Rack::Exporter

    config.middleware.use "RevisionMiddleware"

    ############# ENSURE EDGE MODE FOR IE ###############
    config.action_dispatch.default_headers["X-UA-Compatible"]="IE=edge,chrome=1"


    ############# KEYSTONE ENDPOINT ##############
    config.keystone_endpoint = if ENV['AUTHORITY_SERVICE_HOST'] && ENV['AUTHORITY_SERVICE_PORT']
            proto = ENV['AUTHORITY_SERVICE_PROTO'] || 'http'
            host  = ENV['AUTHORITY_SERVICE_HOST']
            port  = ENV['AUTHORITY_SERVICE_PORT']
            "#{proto}://#{host}:#{port}/v3"
          else
            ENV['MONSOON_OPENSTACK_AUTH_API_ENDPOINT']
          end

    config.debug_api_calls = ENV.has_key?('DEBUG_API_CALLS')
    config.debug_policy_engine = ENV.has_key?('DEBUG_POLICY_ENGINE')


    config.ssl_verify_peer = true
    Excon.defaults[:ssl_verify_peer] = true
    if ENV.has_key?('ELEKTRA_SSL_VERIFY_PEER') and ENV['ELEKTRA_SSL_VERIFY_PEER'] == 'false'
      config.ssl_verify_peer = false
      # set ssl_verify_peer for Excon that is used in FOG to talk with openstack services
      Excon.defaults[:ssl_verify_peer] = false
    end
    puts "=> SSL verify: #{config.ssl_verify_peer}"

    ############## REGION ###############
    config.default_region = ENV['MONSOON_DASHBOARD_REGION']

    ############## CLOUD ADMIN ###############
    config.cloud_admin_domain = ENV.fetch('MONSOON_OPENSTACK_CLOUDADMIN_DOMAIN', 'ccadmin')
    config.cloud_admin_project = ENV.fetch('MONSOON_OPENSTACK_CLOUDADMIN_PROJECT', 'cloud_admin')

    ############## SERVICE USER #############
    config.service_user_id = ENV['MONSOON_OPENSTACK_AUTH_API_USERID']
    config.service_user_password = ENV['MONSOON_OPENSTACK_AUTH_API_PASSWORD']
    config.service_user_domain_name = ENV['MONSOON_OPENSTACK_AUTH_API_DOMAIN']
    config.default_domain = ENV['MONSOON_DASHBOARD_DEFAULT_DOMAIN'] || 'monsoon3'

    # Mailer configuration for inquiries/requests
    config.action_mailer.raise_delivery_errors = true
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
        address:              ENV['MONSOON_DASHBOARD_MAIL_SERVER'],
        port:                 ENV['MONSOON_DASHBOARD_MAIL_SERVER_PORT'] || 25,
        enable_starttls_auto: false
    }
    config.action_mailer.default_options = {
        from: 'Converged Cloud <noreply+ConvergedCloud@sap.corp>'
    }

    # Add middleware healthcheck that to hit the db
    config.middleware.insert_after "Rails::Rack::Logger", "MiddlewareHealthcheck"
  end

end
