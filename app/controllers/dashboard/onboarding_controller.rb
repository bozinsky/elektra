module Dashboard
  class OnboardingController < ::DashboardController
    skip_before_filter :check_terms_of_use
    skip_before_filter :authentication_rescope_token
    skip_before_filter :load_user_projects

    def new_user
      # new user: user has not a role for requested domain or user has no project yet.
      # save current_url in session
      session[:requested_url] = request.env['REQUEST_URI']
      # redirect to user onboarding page.
      if @scoped_domain_name == 'sap_default'
        render 'new_user' and return
      else
        # check for approved inquiry
        if inquiry = services.inquiry.find_by_kind_user_states(DOMAIN_ACCESS_INQUIRY, current_user.id, ['approved'])
          # user has an accepted inquiry for that domain -> onboard user
          params[:terms_of_use] = true
          register_user
          # close inquiry
          services.inquiry.set_state(inquiry.id, :closed, "Domain membership for domain/user #{current_user.id}/#{@scoped_domain_id} granted")
        elsif inquiry = services.inquiry.find_by_kind_user_states(DOMAIN_ACCESS_INQUIRY, current_user.id, ['open'])
          render 'new_user_request_message' and return
        elsif inquiry = services.inquiry.find_by_kind_user_states(DOMAIN_ACCESS_INQUIRY, current_user.id, ['rejected'])
          @processors = Admin::IdentityService.list_scope_admins(domain_id: @scoped_domain_id)
          render 'new_user_reject_message' and return
        else
          render 'new_user_request' and return
        end
      end
    end

    # render new user template
    def new_user_request
    end

    def new_user_request_message
    end

    # onboard new user
    def register_user
      if params[:terms_of_use]
        # user has accepted terms of use -> onboard user
        Admin::OnboardingService.register_user(current_user)
        reset_last_request_cache
        # redirect to domain path
        if plugin_available?('identity')
          redirect_to plugin('identity').domain_path
        else
          redirect_to main_app.root_path
        end
      else
        render action: :new_user
      end
    end

    # new user request
    def register_user_request
      inquiry = nil

      # checkif there is an request already open (can be resubmitted via browser back)
      if services.inquiry.find_by_kind_user_states(DOMAIN_ACCESS_INQUIRY, current_user.id, ['open'])
        redirect_to 'new_user_request_message' and return
      end

      if params[:terms_of_use]
        processors = Admin::IdentityService.list_scope_admins(domain_id: @scoped_domain_id)
        unless processors.blank?
          inquiry = services.inquiry.inquiry_create(
              DOMAIN_ACCESS_INQUIRY,
              "Grant access for user #{current_user.full_name} to Domain #{@scoped_domain_name}",
              current_user,
              current_user.context[:user].to_json,
              processors,
              {},
              @scoped_domain_id
          )
          message = inquiry.errors if inquiry.errors?
        else
          message = "Couldn't find any administrators for this domain!"
        end
      else
        message = "Please accept the terms of use!"
      end

      if message
        flash.now[:error] = message
        render action: :new_user_request
      else
        unless inquiry.errors?
          flash[:notice] = 'Your inquiry was send for further processing'
          render action: :new_user_request_message
        else
          flash.now[:error] = "Your inquiry could not be created because: #{inquiry.errors.full_messages.to_sentence}"
          render action: :new_user_request
        end
      end
    end

    def register_user_approval
      puts "register_user_approval"
    end
  end
end