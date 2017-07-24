module Spree
  StockItem.class_eval do
    after_save :index_stock

    def index_stock
      Indexer.perform_async(:index, variant.product.id)
    end
  end
end

