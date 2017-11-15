# frozen_string_literal: true

module Metrics
  class ApplicationController < DashboardController
    authorization_context 'metrics'
    authorization_required

    def index
      enforce_permissions('metrics:index')
    end

    def maia
      redirect_to "https://maia.#{current_region}.cloud.sap/#{@scoped_domain_name}?x-auth-token=#{current_user.token}"
    end
    
    def server_statistics
      cpu_usage_avarage = services_ng.metrics.get_metrics_for("vcenter_cpu_usage_average",params.require('server_name'))
      mem_usage_avarage = services_ng.metrics.get_metrics_for("vcenter_mem_usage_average",params.require('server_name'))
      
      render json: { 
        cpu_usage_average: [{
          key: 'cpu usage',
          values: cpu_usage_avarage.values
        }],
        mem_usage_average: [{
          key: 'memory usage',
          values: mem_usage_avarage.values
        }]
      }
    end
  end
end
