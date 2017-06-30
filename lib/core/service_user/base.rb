module Core
  module ServiceUser
    class Base
      @@service_user_mutex = Mutex.new

      # # delegate some methods to auth_users
      delegate :token, :token_expired?, :token_expires_at, :domain_id, :domain_name, :context, :id, :default_services_region, :available_services_regions, to: :auth_user

      # Class methods
      class << self
        def load(params={})
          scope_domain = params[:scope_domain]
          return nil if scope_domain.nil?

          @@service_user_mutex.synchronize do
            @service_users ||= {}

            # the service user is created per domain which user accesses.
            service_user = @service_users[scope_domain]
            if service_user.nil?
              @service_users[scope_domain] = self.new(
                  params[:user_id],
                  params[:password],
                  params[:user_domain],
                  scope_domain
              )
            end
          end

          @service_users[scope_domain]
        end
      end

      # Hide the password if this object is being inspected.
      def instance_variables
        super.delete_if{|name| name==:@password}
      end

      # interface to user provided by monsoon-openstack-auth gem.
      def auth_user
        authenticate if @auth_users[@current_domain].nil?
        @auth_users[@current_domain]
      end

      # We could use the token from the auth_user but the fog driver creates a new token that is more up-to-date.
      def token
        driver.auth_token
      end

      # keystone connection for current scope domain.
      def driver
        @drivers[@current_domain]
      end

      def initialize(user_id, password, user_domain_name, scope_domain)
        @user_id = user_id
        @password = password
        @user_domain_name = user_domain_name
        @scope_domain = scope_domain

        @auth_users = {}
        @drivers = {}
        # some service-user requests need to be issued in a different domain;
        # @current_domain tracks which domain scope is being used at the moment
        @current_domain = @scope_domain
        authenticate
      end

      def authenticate
        # @scope_domain is a freindly id. So it can be the name or id
        # That's why we try to load the service user by id and if it
        # raises an error then we try again by name.

        # try to authenticate service user by scope domain id
        scope = {domain: {id: @current_domain}}
        auth_user = @auth_users[@current_domain] = begin
          MonsoonOpenstackAuth.api_client.auth_user(
            @user_id,
            @password,
            domain_name: @user_domain_name,
            scoped_token: scope
          )
        rescue => e
          if e.respond_to?(:code) and [400,401].include?(e.code) and scope[:domain].has_key?(:id)
            #  try to authenticate service user by scope domain name
            scope = {domain: {name: @current_domain}}
            retry
          else
            message = e.message + " (user_id: #{@user_id}, domain: #{@user_domain_name}, scope: #{scope})"
            raise ::Core::ServiceUser::Errors::AuthenticationError.new(message)
          end
        end

        # Unfortunately we can't use Fog directly. Fog tries to authenticate the user
        # by credentials and region using the service catalog. Our backends all use different regions.
        # Therefore we use the auth gem to authenticate the user, get the service catalog and then
        # initialize the fog object.
        begin
          # save connection for current domain. This connection will be used for all further api calls.
          @drivers[@current_domain] = ::Core::ServiceUser::Driver.new({
            auth_url: ::Core.keystone_auth_endpoint,
            region: Core.locate_region(auth_user),
            token: auth_user.token,
            domain_id: auth_user.domain_id
          })
        rescue => e
          message = e.message + " (token: #{auth_user.token}, domain_id: #{auth_user.domain_id}, region: #{Core.locate_region(auth_user)})"
          raise ::Core::ServiceUser::Errors::AuthenticationError.new(message)
        end
        return nil
      end

      def domain_admin_service(name)
        ::Core::ServiceLayer::ServicesManager.service(name,{
          auth_url: ::Core.keystone_auth_endpoint,
          region: Core.locate_region(auth_user),
          token: auth_user.token,
          domain_id: auth_user.domain_id
        })
      end

      def cloud_admin_service(name)
        cloud_admin = MonsoonOpenstackAuth.api_client.auth_user(
          Rails.configuration.service_user_id,
          Rails.configuration.service_user_password,
          domain_name: Rails.configuration.service_user_domain_name,
          scoped_token: {
            project: {
              name: Rails.configuration.cloud_admin_project,
              domain: {name: Rails.configuration.cloud_admin_domain}
            }
          }
        )

        ::Core::ServiceLayer::ServicesManager.service(name,{
          auth_url: ::Core.keystone_auth_endpoint,
          region: Core.locate_region(auth_user),
          token: cloud_admin.token
        })
      end

      # Execute a block in a different domain scope, i.e. driver_method() will
      # use a driver instance that's scoped to the given domain.
      def in_domain_scope(domain)
        previous_domain = @current_domain
        @current_domain = domain
        authenticate unless driver
        result = yield
        @current_domain = previous_domain
        return result
      end

      # execute driver method. Catch 401 errors (token invalid -> expired or revoked)
      def driver_method(method_sym, map, *arguments)
        if map
          driver.map_to(Core::ServiceLayer::Model).send(method_sym, *arguments)
        else
          driver.send(method_sym, *arguments)
        end
      rescue Core::ServiceLayer::Errors::ApiError => e
        # reauthenticate
        authenticate
        # and try again
        if map
          driver.map_to(Core::ServiceLayer::Model).send(method_sym, *arguments)
        else
          driver.send(method_sym, *arguments)
        end
      end

      def users(filter={})
        driver_method(:users, true, filter)
      end

      def find_user(user_id)
        driver_method(:get_user, true, user_id)
      end

      def groups(filter={})
        driver_method(:groups, true, filter)
      end

      def group_members(group_id,filter={})
        driver_method(:group_members, true, group_id,filter)
      end

      def find_group(group_id)
        driver_method(:get_group, true, group_id)
      end

      def find_domain(domain_id)
        driver_method(:get_domain, true, domain_id)
      end

      def roles(filter={})
        driver_method(:roles, true, filter)
      end

      def role_assignments(filter={})
        #filter["scope.domain.id"]=self.domain_id unless filter["scope.domain.id"]
        driver_method(:role_assignments, true, filter)
      end

      def user_projects user_id, filter={}
        driver_method(:user_projects, true, user_id, filter)
      end

      def find_role_by_name(name)
        roles.select { |r| r.name==name }.first
      end

      def find_project_by_name_or_id(name_or_id)
        project = driver_method(:get_project, true, name_or_id) rescue nil
        unless project
          project = driver_method(:projects, true, {domain_id: self.domain_id, name: name_or_id}).first rescue nil
        end
        project
      end

      # def find_project(id)
      #   driver_method(:get_project,true,id)
      # end

      def grant_user_domain_member_role(user_id, role_name)
        role = self.find_role_by_name(role_name)
        driver_method(:grant_domain_user_role, false, self.domain_id, user_id, role.id)
      end

      def grant_project_user_role(project_id, user_id, role_id)
        driver_method(:grant_project_user_role, false, project_id, user_id, role_id)
      end

      def revoke_project_user_role(project_id, user_id, role_id)
        driver_method(:revoke_project_user_role, false, project_id, user_id, role_id)
      end

      def grant_project_group_role(project_id, group_id, role_id)
        driver_method(:grant_project_group_role, false, project_id, group_id, role_id)
      end

      def revoke_project_group_role(project_id, group_id, role_id)
        driver_method(:revoke_project_group_role, false, project_id, group_id, role_id)
      end

      def update_project(id,params)
        driver_method(:update_project, true, id,params)
      end

      def delete_project(id)
        driver_method(:delete_project,false,id)
      end

      def add_user_to_group(user_id, group_name)
        groups = driver_method(:groups, true, {domain_id: self.domain_id, name: group_name}) rescue []
        group = groups.first
        driver_method(:add_user_to_group, false, user_id, group.id) rescue false
      end

      def remove_user_from_group(user_id, group_name)
        groups = driver_method(:groups, true, {domain_id: self.domain_id, name: group_name}) rescue []
        group = groups.first
        driver_method(:remove_user_from_group, false, user_id, group.id) rescue false
      end

      def group_user_check(user_id, group_name)
        groups = driver_method(:groups, true, {domain_id: self.domain_id, name: group_name}) rescue []
        group = groups.first
        driver_method(:group_user_check, false, user_id, group.id) rescue false
      end

      # # A special case of list_scope_admins that returns a list of CC admins.
      # def list_ccadmins
      #   domain_name = Rails.configuration.cloud_admin_domain
      #   in_domain_scope(domain_name) do
      #     domain_id = @auth_users[domain_name].domain_id
      #     list_scope_admins(domain_id: domain_id)
      #   end
      # end
      #
      # def list_scope_resource_admins(scope={})
      #   role = self.find_role_by_name('resource_admin') rescue nil
      #   list_scope_assigned_users(scope.merge(role: role))
      # end
      #
      # # Returns admins for the given scope (e.g. project_id: PROJECT_ID, domain_id: DOMAIN_ID)
      # # This method looks recursively for project, parent_projects and domain admins until it finds at least one.
      # # It should always return a non empty list (at least the domain admins).
      # def list_scope_admins(scope={})
      #   role = self.find_role_by_name('admin') rescue nil
      #   list_scope_assigned_users(scope.merge(role: role))
      # end
      #
      # def list_scope_assigned_users!(options={})
      #   list_scope_assigned_users(options.merge(raise_error: true))
      # end
      #
      # # Returns assigned users for the given scope and role (e.g. project_id: PROJECT_ID, domain_id: DOMAIN_ID, role: ROLE)
      # # This method looks recursively for assigned users of project, parent_projects and domain.
      # def list_scope_assigned_users(options={})
      #   admins = []
      #   project_id = options[:project_id]
      #   domain_id = options[:domain_id]
      #   role = options[:role]
      #   raise_error = options[:raise_error]
      #
      #   # do nothing if role is nil
      #   return admins if role.nil?
      #
      #   begin
      #
      #     if project_id # project_id is presented
      #       # get role_assignments for this project_id
      #       role_assignments = self.role_assignments("scope.project.id" => project_id, "role.id" => role.id, effective: true, include_subtree: true) #rescue []
      #
      #       # load users (not very performant but there is no other option to get users by ids)
      #       role_assignments.each do |r|
      #         unless r.user["id"] == self.id
      #           admin = self.find_user(r.user["id"]) rescue nil
      #           admins << admin if admin
      #         end
      #       end
      #       if admins.length==0 # no admins for this project_id found
      #         # load project
      #         project = self.find_project(project_id) rescue nil
      #         if project
      #           # try to get admins recursively by parent_id
      #           admins = list_scope_assigned_users(project_id: project.parent_id, domain_id: project.domain_id, role: role)
      #         end
      #       end
      #     elsif domain_id # project_id is nil but domain_id is presented
      #       # get role_assignments for this domain_id
      #       role_assignments = self.role_assignments("scope.domain.id" => domain_id, "role.id" => role.id, effective: true) #rescue []
      #       # load users
      #       role_assignments.each do |r|
      #         unless r.user["id"] == self.id
      #           admin = self.find_user(r.user["id"]) rescue nil
      #           admins << admin if admin
      #         end
      #       end
      #     end
      #   rescue => e
      #     raise e if raise_error
      #   end
      #
      #   return admins.delete_if { |a| a.id == nil } # delete crap
      # end
    end
  end
end
