module ServiceLayerNg
  class ObjectStorageService < Core::ServiceLayerNg::Service

   # CONTAINER #

    CONTAINERS_ATTRMAP = {
      # name in API response => name in our model (that is part of this class's interface)
      'bytes' => 'bytes_used',
      'count' => 'object_count',
      'name'  => 'name',
    }
    CONTAINER_ATTRMAP = {
      # name in API => name in our model
      'x-container-object-count'      => 'object_count',
      'x-container-bytes-used'        => 'bytes_used',
      'x-container-meta-quota-bytes'  => 'bytes_quota',
      'x-container-meta-quota-count'  => 'object_count_quota',
      'x-container-read'              => 'read_acl',
      'x-container-write'             => 'write_acl',
      'x-versions-location'           => 'versions_location',
      'x-container-meta-web-index'    => 'web_index',
      'x-container-meta-web-listings' => 'web_file_listing',
    }
    CONTAINER_WRITE_ATTRMAP = {
      # name in our model => name in create/update API request
      'bytes_quota'        => 'x-container-meta-quota-bytes',
      'object_count_quota' => 'x-container-meta-quota-count',
      'read_acl'           => 'x-container-read',
      'write_acl'          => 'x-container-write',
      'versions_location'  => 'x-versions-location',
      'web_index'          => 'x-container-meta-web-index',
      'web_file_listing'   => 'x-container-meta-web-listings',
    }

    def available?(_action_name_sym = nil)
      api.catalog_include_service?('object-store', region)
    end
    
    def list_capabilities
      Rails.logger.debug  "[object_storage-service] -> capabilities -> GET /info"
      response = api.object_storage.list_activated_capabilities
       map_to(ObjectStorage::Capabilities, response.body)
    end
    
    def containers
      Rails.logger.debug  "[object_storage-service] -> containers -> GET /"
      list = api.object_storage.show_account_details_and_list_containers.body
      list.map! do |c|
        container = map_attribute_names(c, CONTAINERS_ATTRMAP)
        container['id'] = container['name'] # name also serves as id() for Core::ServiceLayer::Model
        container
      end
      map_to(ObjectStorage::Container, list)
    end
    
    def container_details_and_list_objects(container_name)
      Rails.logger.debug  "[object_storage-service] -> find_container -> GET /"
      response = api.object_storage.show_container_details_and_list_objects(container_name)
      map_to(ObjectStorage::Container, response.body)
    end
    
    def container_metadata(container_name)
      Rails.logger.debug  "[object_storage-service] -> container_metadata -> HEAD /v1/{account}/{container}"
      response = api.object_storage.show_container_metadata(container_name)
      data = build_container_header_data(response,container_name)
      map_to(ObjectStorage::Container, data)
    end

    def new_container(attributes={})
      Rails.logger.debug  "[object_storage-service] -> new_container"
      map_to(ObjectStorage::Container, attributes)
    end

    def empty(container_name)
      Rails.logger.debug  "[object_storage-service] -> empty -> #{container_name}"
      targets = list_objects(container_name).map do |obj|
        { container: container_name, object: obj['path'] }
      end
      bulk_delete(targets)
    end
    
    def empty?(container_name)
      Rails.logger.debug  "[object_storage-service] -> empty? -> #{container_name}"
      list_objects(container_name, limit: 1).count == 0
    end 

    def create_container(params = {})
      Rails.logger.debug  "[object_storage-service] -> create_container"
      Rails.logger.debug  "[object_storage-service] -> parameter:#{params}"
      name = params.delete(:name)
      api.object_storage.create_container(name, Misty.to_json(params)).body
    end
    
    def delete_container(container_name)
      Rails.logger.debug  "[object_storage-service] -> delete_container -> #{container_name}"
      api.object_storage.delete_container(container_name).body
    end

    def update_container(container_name, params={})
      # update container properties and access control
      Rails.logger.debug  "[object_storage-service] -> update_container -> #{container_name}"
      Rails.logger.debug  "[object_storage-service] -> parameter:#{params}"

      request_params = map_attribute_names(params, CONTAINER_WRITE_ATTRMAP)

      # convert difference between old and new metadata into a set of changes
      old_metadata = params['original_metadata']
      new_metadata = params['metadata']
      if old_metadata.nil? && !new_metadata.nil?
        raise InputError, 'cannot update metadata without knowing the current metadata'
      end
      (old_metadata || {}).each do |key, value|
        unless new_metadata.has_key?(key)
          request_params["X-Remove-Container-Meta-#{key}"] = "1"
        end
      end
      (new_metadata || {}).each do |key, value|
        if old_metadata[key] != value
          request_params["X-Container-Meta-#{key}"] = value
        end
      end
      
      Rails.logger.debug  "[object_storage-service] -> headers:#{request_params}"

      # TODO: set metadata is not working right now, we need support for misty to set the request header
      #       bevore the request is send to the server
      #api.object_storage.set_custom_request_headers(request_params)
      #api.object_storage.create_update_or_delete_container_metadata(container_name)
      
      # workarround - overwrite client with headers
      get_client(request_params).create_update_or_delete_container_metadata(container_name)
    end

    # OBJECTS # 

    OBJECTS_ATTRMAP = {
      # name in API response => name in our model (that is part of this class's interface)
      'bytes'         => 'size_bytes',
      'content_type'  => 'content_type',
      'hash'          => 'md5_hash',
      'last_modified' => 'last_modified_at',
      'name'          => 'path',
      'subdir'        => 'path', # for subdirectories, only this single attribute is given
    }
    OBJECT_ATTRMAP = {
      'content-length' => 'size_bytes',
      'content-type'   => 'content_type',
      'etag'           => 'md5_hash',
      'last-modified'  => 'last_modified_at',
      'x-timestamp'    => 'created_at',
      'x-delete-at'    => 'expires_at',
    }
    OBJECT_WRITE_ATTRMAP = {
      # name in our model => name in create/update API request
      'content_type'   => 'Content-Type',
      # 'expires_at'     => 'X-Delete-At', # this is special-cased in update_object()
    }

    def object_metadata(container_name,path)
      Rails.logger.debug  "[object_storage-service] -> find_object -> #{container_name}, #{path}"
      return nil if container_name.blank? or path.blank?

      response = api.object_storage.show_object_metadata(container_name, path)
      data = build_object_header_data(response,container_name,path)
      map_to(ObjectStorage::ObjectNg, data)
    end

    def object_content(container_name, path)
      Rails.logger.debug  "[object_storage-service] -> object_content_and_metadata -> #{container_name}, #{path}"
      api.object_storage.get_object_content_and_metadata(container_name,path).body
    end

    def list_objects(container_name, options={})
      Rails.logger.debug  "[object_storage-service] -> list_objects -> #{container_name}"
      list = api.object_storage.show_container_details_and_list_objects(container_name, options).body
      list.map! do |o|
        object = map_attribute_names(o, OBJECTS_ATTRMAP)
        object['id'] = object['path'] # path also serves as id() for Core::ServiceLayer::Model
        object['container_name'] = container_name
        if object.has_key?('last_modified_at')
          object['last_modified_at'] = DateTime.iso8601(object['last_modified_at']) # parse date
        end
        object
      end
    end
    
    def list_objects_at_path(container_name, path, filter={})
      Rails.logger.debug  "[object_storage-service] -> list_objects_at_path -> #{container_name}, #{path}, #{filter}"
      path += '/' if !path.end_with?('/') && !path.empty?
      result = list_objects(container_name, filter.merge(prefix: path, delimiter: '/'))
      # if there is a pseudo-folder at `path`, it will be in the result, too;
      # filter this out since we only want stuff below `path`
      objects = result.reject { |obj| obj['id'] == path }
      map_to(ObjectStorage::Object, objects)
    end

    def list_objects_below_path(container_name, path, filter={})
      Rails.logger.debug  "[object_storage-service] -> list_objects_below_path -> #{container_name}, #{path}, #{filter}"
      path += '/' if !path.end_with?('/') && !path.empty?
      objects =  list_objects(container_name, filter.merge(prefix: path))
      map_to(ObjectStorage::Object, objects)
    end

    def copy_object(source_container_name, source_path, target_container_name, target_path, options={})
      Rails.logger.debug  "[object_storage-service] -> copy_object -> #{source_container_name}/#{source_path} to #{target_container_name}/#{target_path}"
      Rails.logger.debug  "[object_storage-service] -> copy_object -> Options: #{options}"
      headers = {
          'Destination' => "/#{target_container_name}/#{target_path}"
      }.merge(options)
      api.object_storage.copy_object(source_container_name,source_path,custom_header(headers))
    end
    
    def move_object(source_container_name, source_path, target_container_name, target_path, options={})
      Rails.logger.debug  "[object_storage-service] -> move_object -> #{source_container_name}/#{source_path} to #{target_container_name}/#{target_path}"
      Rails.logger.debug  "[object_storage-service] -> move_object -> Options: #{options}"
      copy_object(source_container_name, source_path, target_container_name, target_path, options.merge(with_metadata: true))
      delete_object(source_container_name, source_path)
    end

    def bulk_delete(targets)
      Rails.logger.debug  "[object_storage-service] -> bulk_delete"
      Rails.logger.debug  "[object_storage-service] -> targets: #{targets}"

#      TODO:
#      https://github.com/fog/fog-openstack/blob/master/lib/fog/storage/openstack/requests/delete_multiple_objects.rb
#      DELETE with body, that is sadly not possible yet in misty
#      https://github.com/flystack/misty/blob/master/lib/misty/http/method_builder.rb#L25
#      capabilities = list_capabilities
#      if capabilities.attributes.has_key?('bulk_delete')
#        # assemble the request body containing the paths to all targets
#        body = ""
#        targets.each do |target|
#          unless target.has_key?(:container)
#            raise ArgumentError, "malformed target #{target.inspect}"
#          end
#          body += target[:container]
#          if target.has_key?(:object)
#            body += "/" + target[:object]
#          end
#          body += "\n"
#        end
#
#        # TODO: the bulk delete request is missing in Fog
#        @fog.send(:request, {
#          expects: 200,
#          method:  'DELETE',
#          path:    '',
#          query:   { 'bulk-delete' => 1 },
#          headers: { 'Content-Type' => 'text/plain' },
#          body:    body,
#        })
#      else
        targets.each do |target|
          unless target.has_key?(:container)
            raise ArgumentError, "malformed target #{target.inspect}"
          end

          if target.has_key?(:object)
            delete_object(target[:container],target[:object])
          else
            delete_container(target[:container])
          end
        end
#      end
    end
    
    def create_object(container_name, path, contents)
      path = sanitize_path(path)
      Rails.logger.debug  "[object_storage-service] -> create_object -> #{container_name}, #{path}"

      # content type "application/directory" is needed on pseudo-dirs for
      # staticweb container listing to work correctly
      headers = {}
      headers['Content-Type'] = 'application/directory' if path.end_with?('/')
      headers['Content-Type'] = ''
      # `contents` is an IO object to allow for easy future expansion to
      # more clever upload strategies (e.g. SLO); for now, we just send
      # everything at once
      
      header = Misty::HTTP::Header.new(
        'Content-Type' => ''
      )
      api.object_storage.create_or_replace_object(container_name, path, contents.read, header)
    end

    def delete_object(container_name,path)
      Rails.logger.debug  "[object_storage-service] -> delete_object -> #{container_name}, #{path}"
      api.object_storage.delete_object(container_name,path)
    end
    
    def update_object(container_name,path)
      Rails.logger.debug  "[object_storage-service] -> update_object -> #{container_name}, #{path}"
      # TODO
    end

    def create_folder(container_name, path)
      Rails.logger.debug  "[object_storage-service] -> create_folder -> #{container_name}, #{path}"
      # a pseudo-folder is created by writing an empty object at its path, with
      # a "/" suffix to indicate the folder-ness
      api.object_storage.create_or_replace_object(container_name, sanitize_path(path) + '/')
    end
    
    def delete_folder(container_name, path)
      Rails.logger.debug  "[object_storage-service] -> delete_folder -> #{container_name}, #{path}"
      targets = list_objects_below_path(container_name, sanitize_path(path) + '/').map do |obj|
        { container: container_name, object: obj.path }
      end
      bulk_delete(targets)
    end

   private

    # Rename keys in `data` using the `attribute_map` and delete unknown keys.
    def map_attribute_names(data, attribute_map)
      data.transform_keys { |k| attribute_map.fetch(k, nil) }.reject { |key,_| key.nil? }
    end

    def extract_metadata_tags(headers, prefix)
      result = {}
      headers.each do |key,value|
        if key.start_with?(prefix)
          result[key.sub(prefix, '')] = value
        end
      end
      return result
    end
    
    def build_container_header_data(response,container_name = nil)
      headers = {}
      response.header.each_header{|key,value| headers[key] = value}
      header_hash = map_attribute_names(headers, CONTAINER_ATTRMAP)
      
      # enrich data with additional information
      header_hash['id']               = header_hash['name'] = container_name
      #header_hash['public_url']      = fog_public_url(container_name)
      header_hash['web_file_listing'] = header_hash['web_file_listing'] == 'true' # convert to Boolean
      header_hash['metadata']         = extract_metadata_tags(headers, 'x-container-meta-').reject do |key, value|
        # skip metadata fields that are recognized by us
        CONTAINER_ATTRMAP.has_key?('x-container-meta-' + key)
      end
      
      header_hash
    end
    
    def build_object_header_data(response,container_name = nil, path = nil)
      headers = {}
      response.header.each_header{|key,value| headers[key] = value}
      header_hash = map_attribute_names(headers, OBJECT_ATTRMAP)
      header_hash['id']               = header_hash['path'] = path
      header_hash['container_name']   = container_name
      #header_hash['public_url']       = fog_public_url(container_name, path)
      header_hash['last_modified_at'] = DateTime.httpdate(header_hash['last_modified_at']) # parse date
      header_hash['created_at']       = DateTime.strptime(header_hash['created_at'], '%s') # parse UNIX timestamp
      header_hash['expires_at']       = DateTime.strptime(header_hash['expires_at'], '%s') if header_hash.has_key?('expires_at') # optional!
      header_hash['metadata']         = extract_metadata_tags(headers, 'X-Object-Meta-')
      
      header_hash
    end

    def custom_header(headers)
      # stringify keys and values
      # https://stackoverflow.com/questions/34595141/process-nested-hash-to-convert-all-values-to-strings
      headers.deep_merge!(headers) {|_,_,v| v.to_s}
      headers.stringify_keys!
      # create custom header
      Misty::HTTP::Header.new(headers)
    end

    # remove duplicate slashes that might have been created by naive path
    def sanitize_path(path)
      # joining (e.g. `foo + "/" + bar`)
      path = path.gsub(/^\/+/, '/')

      # remove leading and trailing slash
      return path.sub(/^\//, '').sub(/\/$/, '')
    end

  end
end