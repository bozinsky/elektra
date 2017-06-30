module ServiceLayer

  class IdentityService < Core::ServiceLayer::Service

    attr_reader :region

    def driver
      unless @driver
        auth = {
          auth_url:   self.auth_url,
          region:     self.region,
          token:      self.token,
          domain_id:  self.domain_id,
          project_id: self.project_id
        }
        # cannot use services.resource_management.available? directly because
        # `services` might not have been set if this service instance was
        # created via e.g. service_user.domain_admin_service()
        @driver = Identity::Driver::Fog.new(auth, with_limes: services.try(&:resource_management).try(&:available?))
      end
      @driver
    end

    def available?(action_name_sym=nil)
      not current_user.service_url('identity', region: region).nil?
    end

    def has_projects?
      driver.auth_projects.count>0
    end

    ##################### DOMAINS #########################
    def find_domain id
      return nil if id.blank?
      driver.map_to(Identity::Domain).get_domain(id)
    end

    def new_domain(attributes={})
      Identity::Domain.new(@driver, attributes)
    end

    def auth_domains
      @domains ||= driver.auth_domains.collect { |attributes| Identity::Domain.new(@driver, attributes) }
    end

    def domains(filter={})
      driver.map_to(Identity::Domain).domains(filter)
    end

    ###################### USERS ##########################
    def users(filter={})
      driver.map_to(Identity::User).users(filter)
    end

    def find_user(id)
      driver.map_to(Identity::User).get_user(id)
    end

    def new_user(attributes={})
      Identity::User.new(driver, attributes)
    end

    def delete_user(id)
      driver.delete_user(id)
    end


    ##################### PROJECTS #########################
    def new_project(attributes={})
      Identity::Project.new(driver, attributes)
    end

    def find_project(id=nil, options=[])
      return nil if id.blank?
      driver.map_to(Identity::Project).get_project(id, options)
    end

    def projects_by_user_id(user_id)
      driver.map_to(Identity::Project).user_projects(user_id)
    end

    # def auth_projects(domain_id=nil)
    #   # caching
    #   @auth_projects ||= driver.map_to(Identity::Project).auth_projects
    #
    #   return @auth_projects if domain_id.nil?
    #   @auth_projects.select { |project| project.domain_id==domain_id }
    # end
    #
    # def auth_projects_tree(projects=auth_projects)
    #   if projects && !projects.first.kind_of?(Identity::Project)
    #     projects.collect! { |project| ::Identity::Project.new(@driver, project.attributes.merge(id:project.id)) }
    #   end
    #   @projects_tree ||= Rails.cache.fetch("#{current_user.token}/auth_projects_tree", expires_in: 60.seconds) do
    #     Identity::ProjectTree.new(projects)
    #   end
    # end
    #
    # def clear_auth_projects_tree_cache
    #   Rails.cache.delete("#{current_user.token}/auth_projects_tree")
    # end

    def projects(filter={})
      driver.map_to(Identity::Project).projects(filter)
    end

    def grant_project_user_role_by_role_name(project_id, user_id, role_name)
      role = service_user.find_role_by_name(role_name)
      driver.grant_project_user_role(project_id, user_id, role.id)
      role
    end

    def grant_project_user_role(project_id, user_id, role_id)
      driver.grant_project_user_role(project_id, user_id, role_id)
    end

    def revoke_project_user_role(project_id, user_id, role_id)
      driver.revoke_project_user_role(project_id, user_id, role_id)
    end

    def grant_project_group_role(project_id, group_id, role_id)
      driver.grant_project_group_role(project_id, group_id, role_id)
    end

    def revoke_project_group_role(project_id, group_id, role_id)
      driver.revoke_project_group_role(project_id, group_id, role_id)
    end

    ##################### CREDENTIALS #########################
    def new_credential(attributes={})
      Identity::OsCredential.new(@driver, attributes)
    end

    def find_credential(id=nil)
      return nil if id.blank?
      driver.map_to(Identity::OsCredential).get_os_credential(id)
    end

    def credentials(options={})
      @user_credentials ||= driver.map_to(Identity::OsCredential).os_credentials(user_id: @current_user.id)
    end

    ####################### ROLES ###########################
    # current_user roles
    def roles
      @roles ||= driver.map_to(Identity::Role).roles
    end

    def user_groups
      driver.map_to(Identity::Group).user_groups(@current_user.id)
    end

    def groups(filter={})
      driver.map_to(Identity::Group).groups(filter)
    end

    def create_group(attributes)
      driver.map_to(Identity::Group).create_group(attributes)
    end

    def delete_group(group_id)
      driver.delete_group(group_id)
    end

    def new_group(attributes={})
      Identity::Group.new(driver, attributes)
    end

    def find_group(id)
      driver.map_to(Identity::Group).get_group(id)
    end

    def group_members(group_id,filter={})
      driver.map_to(Identity::User).group_members(group_id,filter)
    end

    def add_group_member(group_id,user_id)
      driver.add_group_member(group_id,user_id)
    end

    def remove_group_member(group_id,user_id)
      driver.remove_group_member(group_id,user_id)
    end

    def find_role(id)
      return nil if id.blank?
      roles.select { |r| r.id==id }.first
    end

    def find_role_by_name(name)
      roles.select { |r| r.name==name }.first
    end

    def role_assignments(filter={})
      driver.map_to(Identity::RoleAssignment).role_assignments(filter)
    end

    def grant_domain_user_role(domain_id, user_id, role_id)
      driver.grant_domain_user_role(domain_id, user_id, role_id)
    end

    def revoke_domain_user_role(domain_id, user_id, role_id)
      driver.revoke_domain_user_role(domain_id, user_id, role_id)
    end


    ###################### TOKENS ###########################
    def validate_token(token)
      driver.validate(token) rescue false
    end


  end
end
