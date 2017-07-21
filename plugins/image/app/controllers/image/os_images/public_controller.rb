# frozen_string_literal: true

module Image
  module OsImages
    # Public Images
    class PublicController < OsImagesController
      def unpublish
        @image = services_ng.image.new_image
        @image.id = params[:public_id]
        @image.unpublish
        @success = (@image.visibility == 'private')
      end

      protected

      def filter_params
        { sort_key: 'name', visibility: 'public' }
      end
    end
  end
end
