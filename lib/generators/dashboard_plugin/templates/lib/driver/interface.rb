module %{PLUGIN_NAME}
  module Driver
    # Neutron calls
    class Interface < DomainModelServiceLayer::Driver::Base
      ###################### NETWORKS #######################
      def test(filter={})
        raise DomainModelServiceLayer::Errors::NotImplemented
      end
    end
  end
end