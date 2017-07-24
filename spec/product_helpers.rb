module Spree
  Product.class_eval do
    after_save :elasticsearch_index
    after_destroy :elasticsearch_delete

    private
      def elasticsearch_index
        Indexer.perform_async(:index,  self.id)
      end

      def elasticsearch_delete
        Indexer.perform_async(:delete,  self.id)
      end
  end
end