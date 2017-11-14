module ServiceLayerNg

  class MetricsService < Core::ServiceLayerNg::Service

    def available?(_action_name_sym = nil)
      api.catalog_include_service?('metrics', region)
    end
    
    def cpu_usage_avarage(vmware_name, start_time = Time.now - 60*60*24, end_time = Time.now, step = 240)
      Rails.logger.debug  "[metrics-service] -> cpu_usage_avarage -> GET /query_range/"
      response = api.metrics.query_range(
        'query' => "vcenter_cpu_usage_average{vmware_name='#{vmware_name}'}",
        'start' => start_time.to_i,
        'end'   => end_time.to_i,
        'step'  => step
       )
       map_to(Metrics::MetricsData, response.body['data']['result'][0])
    end
  end
end