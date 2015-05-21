class AuthenticatedUserController < ApplicationController
  # load region, domain and project if given
  prepend_before_filter do
    p ">>>>>>>>>>>>>>>>>"
    # redirect to the same url with default domain unless domain_id is given
    redirect_to url_for(params.merge(domain_id: MonsoonOpenstackAuth.default_domain.id)) unless params[:domain_id]
    
    @region     ||= MonsoonOpenstackAuth.configuration.default_region
    @domain_id  ||= params[:domain_id]
    @project_id ||= params[:project_id]    
  end
   
  authentication_required domain: -> c { p ":::::::::::::::"; c.instance_variable_get("@domain_id") }, project: -> c { c.instance_variable_get('@project_id') }
  
  before_filter :check_terms_of_use
  
  include OpenstackServiceProvider::Services  
  
  def check_terms_of_use
    technical_user = TechnicalUser.new(auth_session)
    
    p ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    p current_user.roles
    p technical_user.sandbox_exists?
    p ':::::::::::::::::::::::::::::'
    
    unless technical_user.sandbox_exists?#current_user.roles.length>0 or technical_user.sandbox_exists?
      session[:requested_url] = request.env['REQUEST_URI']
      redirect_to users_terms_of_use_path
    end
  end
end