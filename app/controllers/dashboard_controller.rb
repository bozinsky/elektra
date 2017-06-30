# frozen_string_literal: true

# This class guarantees that the user is logged in and his token is rescoped.
# All subclasses which require a logged in user should inherit from this class.
class DashboardController < ::ScopeController
  include UrlHelper
  include UserApiClient
  include HelpTexts

  prepend_before_filter do
    requested_url = request.env['REQUEST_URI']
    referer_url   = request.referer
    referer_url   = begin
                      "#{URI(referer_url).path}?#{URI(referer_url).query}"
                    rescue
                      nil
                    end

    unless params[:after_login]
      if requested_url =~ /(\?|\&)modal=true/ && referer_url =~ /(\?|\&)overlay=.+/
        params[:after_login] = referer_url
      else
        params[:after_login] = requested_url
      end
    end
  end

  before_filter :load_help_text

  # authenticate user -> current_user is available
  authentication_required(
    domain: ->(c) { c.instance_variable_get('@scoped_domain_id') },
    domain_name: ->(c) { c.instance_variable_get('@scoped_domain_name') },
    project: ->(c) { c.instance_variable_get('@scoped_project_id') },
    rescope: false,
    two_factor: :two_factor_required?,
    except: :terms_of_use
  )

  # after_login is used by monsoon_openstack_auth gem.
  # After the authentication process has finished the
  # after_login can be removed.
  before_filter { params.delete(:after_login) }

  # check if user has accepted terms of use. Otherwise
  # it is a new, unboarded user.
  before_filter :check_terms_of_use, except: %i[accept_terms_of_use terms_of_use]
  # rescope token
  before_filter :rescope_token, except: [:terms_of_use]
  # user is authenticated -> register api_client for current user
  before_action :set_user_api_client

  before_filter :raven_context, except: [:terms_of_use]

  before_filter :load_user_projects, :set_webcli_endpoint, except: [:terms_of_use]
  before_filter :set_mailer_host

  # even if token is not expired yet we get sometimes the
  # error "token not found" so we try to catch this error here
  # and redirect user to login screen
  rescue_from 'Excon::Error::NotFound' do |error|
    if error.message.match(/Could not find token/i) ||
       error.message.match(/Failed to validate token/i)
      redirect_to monsoon_openstack_auth.login_path(
        domain_name: @scoped_domain_name,
        after_login: params[:after_login]
      )
    else
      render_exception_page(error, title: 'Backend Service Error')
    end
  end

  rescue_from 'Core::ServiceLayer::Errors::ApiError' do |error|
    if error.response_data && error.response_data['error'] &&
       error.response_data['error']['code'] == 0o3
      render_exception_page(
        error,
        title: 'Permission Denied',
        description: error.response_data['error']['message'] ||
                     'You are not authorized to request this page.'
      )
    else
      render_exception_page(error, title: 'Backend Service Error')
    end
  end

  rescue_from 'Excon::Error::Unauthorized',
              'MonsoonOpenstackAuth::Authentication::NotAuthorized' do
    redirect_to monsoon_openstack_auth.login_path(
      domain_name: @scoped_domain_name,
      after_login: params[:after_login]
    )
  end

  # catch all mentioned errors and render error page
  rescue_and_render_exception_page [
    {
      'MonsoonOpenstackAuth::Authorization::SecurityViolation' => {
        title: 'Unauthorized',
        sentry: false,
        warning: true,
        status: 401,
        description: lambda { |e, _c|
          m = 'You are not authorized to view this page.'
          if e.involved_roles && e.involved_roles.length.positive?
            m += " Please check (role assignments) if you have one of the \
                   following roles: #{e.involved_roles.flatten.join(', ')}."
          end
          m
        }
      }
    },
    { 'Core::Error::ProjectNotFound' => { title: 'Project Not Found' } }
  ]

  def rescope_token
    role_assignments = service_user_ng do
      Identity::RoleAssignmentNg.all('user.id' => current_user.id,
                                     'scope.domain.id' => @scoped_domain_id,
                                     'effective' => true)
    end

    if @scoped_project_id.nil? && role_assignments.empty?
      authentication_rescope_token(domain: nil, project: nil)
    else
      authentication_rescope_token
    end
  end

  def check_terms_of_use
    render(action: :accept_terms_of_use) && return unless tou_accepted?
  end

  def accept_terms_of_use
    if params[:terms_of_use]
      # user has accepted terms of use -> onboard user
      UserProfile.create_with(
        name: current_user.name,
        email: current_user.email,
        full_name: current_user.full_name
      ).find_or_create_by(uid: current_user.id).domain_profiles.create(
        domain_id: current_user.user_domain_id,
        tou_version: Settings.actual_terms.version
      )
      reset_last_request_cache
      # redirect to domain path
      if plugin_available?('identity')
        redirect_to plugin('identity').domain_path
      else
        redirect_to main_app.root_path
      end
    else
      check_terms_of_use
    end
  end

  def terms_of_use
    if current_user
      @tou = UserProfile.tou(current_user.id,
                             current_user.user_domain_id,
                             Settings.actual_terms.version)
    end
    render action: :terms_of_use
  end

  def find_users_by_name
    name = params[:name] || params[:term] || ''
    users = UserProfile.search_by_name(name)
    # sample users uniq
    result = users.each_with_object({}) do |u, hash|
      hash[u.name] ||= { id: u.uid, name: u.name, full_name: u.full_name,
                         email: u.email }
    end

    render json: result.values
  end

  def find_cached_domains
    name = params[:name] || params[:term] || ''
    domains = FriendlyIdEntry.search('Domain', nil, name)
    render json: domains.collect { |d| { id: d.key, name: d.name } }.to_json
  end

  def find_cached_projects
    name = params[:name] || params[:term] || ''
    projects = FriendlyIdEntry.search('Project', @scoped_domain_id, name)
    render json: projects.collect do |project|
      { id: project.key, name: project.name }
    end.to_json
  end

  def two_factor_required?
    if ENV['TWO_FACTOR_AUTH_DOMAINS']
      return ENV['TWO_FACTOR_AUTH_DOMAINS'].gsub(/\s+/, '').split(',').include?(@scoped_domain_name)
    end
    false
  end

  protected

  helper_method :release_state

  # Overwrite this method in your controller if you want to set the release
  # state of your plugin to a different value. A tag will be displayed in the
  # main toolbar next to the page header
  # DON'T OVERWRITE THE VALUE HERE IN THE DASHBOARD CONTROLLER
  # Possible values:
  # ----------------
  # "public_release"  (plugin is properly live and works, default)
  # "experimental"    (for plugins that barely work or don't work at all)
  # "tech_preview"    (early preview for a new feature that probably still
  #                    has several bugs)
  # "beta"            (if it's almost ready for public release)
  def release_state
    'public_release'
  end

  def show_beta?
    params[:betafeatures] == 'showme'
  end
  helper_method :show_beta?

  def raven_context
    @sentry_user_context = {
      ip_address: request.ip,
      id: current_user.id,
      email: current_user.email,
      username: current_user.name,
      domain: current_user.user_domain_name,
      name: current_user.full_name
    }.reject { |_, v| v.nil? }

    Raven.user_context(
      @sentry_user_context
    )

    tags = {}
    tags[:request_id] = request.uuid if request.uuid
    tags[:plugin] = plugin_name if try(:plugin_name).present?
    if current_user.domain_id
      tags[:domain_id] = current_user.domain_id
      tags[:domain_name] = current_user.domain_name
    elsif current_user.project_id
      tags[:project_id] = current_user.project_id
      tags[:project_name] = current_user.project_name
      tags[:project_domain_id] = current_user.project_domain_id
      tags[:project_domain_name] = current_user.project_domain_name
    end
    @sentry_tags_context = tags
    Raven.tags_context(tags)
  end

  def load_user_projects
    # get all projects for user (this might be expensive,
    # might need caching, ajaxifying, ...)
    @user_domain_projects ||= begin
      service_user_ng do
        Identity::ProjectNg.user_projects(
          current_user.id, domain_id: @scoped_domain_id
        ).sort_by(&:name)
      end
    rescue
      []
    end

    return unless @scoped_project_id
    @active_project = Identity::ProjectNg.find(
      @scoped_project_id, subtree_as_ids: true, parents_as_ids: true
    )
    FriendlyIdEntry.update_project_entry(@active_project)
  end

  def set_webcli_endpoint
    @webcli_endpoint = current_user.service_url('webcli')
  end

  def tou_accepted?
    # Consider that every plugin controller inhertis from dashboard controller
    # and check_terms_of_use method is called on every request.
    # In order to reduce api calls we cache the result of new_user?
    # in the session for 5 minutes.
    is_cache_expired = current_user.id != session[:last_user_id] ||
                       session[:last_request_timestamp].nil? ||
                       (session[:last_request_timestamp] < Time.now - 5.minute)
    if is_cache_expired
      session[:last_request_timestamp] = Time.now
      session[:last_user_id] = current_user.id
      session[:tou_accepted] =
        if UserProfile.tou_accepted?(current_user.id, current_user.user_domain_id, Settings.actual_terms.version)
          session[:tou_accepted] = true
        else
          session[:tou_accepted] = false
        end
    end
    session[:tou_accepted]
  end

  def reset_last_request_cache
    session[:last_request_timestamp] = nil
    session[:last_user_id] = nil
  end

  def set_mailer_host
    ActionMailer::Base.default_url_options[:host] = request.host_with_port
    ActionMailer::Base.default_url_options[:protocol] = request.protocol
  end

  def project_id_required
    raise Core::Error::ProjectNotFound, 'The project you have requested was not found.' if params[:project_id].blank?
  end
end
