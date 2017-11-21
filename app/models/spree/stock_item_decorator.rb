module Spree
  StockItem.class_eval do
    after_save :index_stock

    def index_stock
      begin
        Indexer.perform_async(:index, variant.product.id)
        rescue
      end
    end
  end
end

