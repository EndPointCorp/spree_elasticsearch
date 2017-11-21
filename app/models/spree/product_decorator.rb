module Spree
  Product.class_eval do

    include Elasticsearch::Model
    # include Elasticsearch::Model::Callbacks

    Elasticsearch::Client.new host: ENV['ELASTICSEARCH_URL']

    # after_save    { logger.debug ["Updating document... ", __elasticsearch__.index_document ].join }
    # after_destroy { logger.debug ["Deleting document... ", __elasticsearch__.delete_document].join }

    #after_save    { Indexer.perform_async(:index,  self.id);  }
    #after_destroy { Indexer.perform_async(:delete, self.id) }


    after_save :update_product_index
    after_destroy :delete_product_index

    def update_product_index
      begin
        Indexer.perform_async(:index, variant.product.id)
      rescue

      end
    end

    def delete_product_index
      begin
        Indexer.perform_async(:delete, variant.product.id)
      rescue
      end
    end

    index_name "spree_#{Rails.env}"
    document_type 'spree_product'


    settings index: {
      number_of_shards: 1,
      number_of_replicas: 3,
      analysis: {
        analyzer: {
          ik_pinyin_analyzer: {
            type: 'custom',
            tokenizer: 'ik_smart',
            filter: %w[pinyin_filter word_delimiter]
          }
        },
        filter: {
          pinyin_filter: {
            type: 'pinyin',
            first_letter: 'prefix',
            padding_char: ' '
          }
        }
      }

    } do
      mapping do
        indexes :name, type: 'keyword', boost: 100, fields: {
          pinyin: {
            type: 'text',
            store: 'no',
            term_vector: 'with_positions_offsets',
            analyzer: 'ik_pinyin_analyzer',
            boost: 10
          }
        }

        indexes :description, analyzer: 'snowball'
        indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
        indexes :price, type: 'double'
        indexes :origin_price, type: 'double'
        indexes :sku, type: 'keyword', index: 'not_analyzed'
        indexes :taxon_ids, type: 'keyword', index: 'not_analyzed'
        indexes :taxon_names, type: 'keyword', index: 'not_analyzed'
        indexes :properties, type: 'keyword', index: 'not_analyzed'
        indexes :stock, type: 'integer', index: 'not_analyzed'
        indexes :backorderable, type: 'bool', index: 'not_analyzed'
      end
    end



    def as_indexed_json(options={})
      result = as_json({
        methods: [:price, :origin_price, :sku],
        only: [:available_on, :description, :name],
        include: {
          variants: {
            only: [:sku],
            include: {
              option_values: {
                only: [:name, :presentation]
              }
            }
          }
        }
      })
      result[:properties] = property_list unless property_list.empty?
      result[:taxon_ids] = taxons.map(&:self_and_ancestors).flatten.uniq.map(&:id) unless taxons.empty?
      result[:taxon_names] = taxons.map(&:self_and_ancestors).flatten.uniq.map(&:name) unless taxons.empty?
      result[:stock] = total_on_hand
      result[:backorderable] = master.try(:is_backorderable?)
      result
    end

    def self.get(product_id)
      Elasticsearch::Model::Response::Result.new(__elasticsearch__.client.get index: index_name, type: document_type, id: product_id)
    end

    # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
    class Product::ElasticsearchQuery
      include ::Virtus.model

      attribute :from, Integer, default: 0
      attribute :price_min, Float
      attribute :price_max, Float
      attribute :properties, Hash
      attribute :query, String
      attribute :taxons, Array
      attribute :browse_mode, Boolean
      attribute :sorting, String

      # When browse_mode is enabled, the taxon filter is placed at top level. This causes the results to be limited, but facetting is done on the complete dataset.
      # When browse_mode is disabled, the taxon filter is placed inside the filtered query. This causes the facets to be limited to the resulting set.

      # Method that creates the actual query based on the current attributes.
      # The idea is to always to use the following schema and fill in the blanks.
      # {
      #   query: {
      #     filtered: {
      #       query: {
      #         query_string: { query: , fields: [] }
      #       }
      #       filter: {
      #         and: [
      #           { terms: { taxons: [] } },
      #           { terms: { properties: [] } }
      #         ]
      #       }
      #     }
      #   }
      #   filter: { range: { price: { lte: , gte: } } },
      #   sort: [],
      #   from: ,
      #   aggregations:
      # }



      # query = {
      #     query: {
      #         bool: {
      #             must: [
      #                 { match_phrase: { 'name.pinyin': q } },
      #             ],
      #             filter: [
      #                 { range: { available_on: { lte: 'now' } } },
      #                 { range: { price: { gte: 2, lte: 10 } } }
      #             ]
      #         }
      #     }
      # }
      def to_hash
        q = { bool: {} }
        unless query.blank? # nil or empty
          # q = { query_string: { query: query, fields: ['name^5','description','sku'], default_operator: 'AND', use_dis_max: true } }
          q = {
            bool: {
              must: [
                  { match_phrase: { 'name.pinyin': query } },
              ],
              filter: [
                  { range: { available_on: { lte: 'now' } } },
                  { range: { price: { gte: 2, lte: 10 } } }
              ]
            }
          }
        end
        query = q

        and_filter = []
        unless @properties.nil? || @properties.empty?
          # transform properties from [{"key1" => ["value_a","value_b"]},{"key2" => ["value_a"]}
          # to { terms: { properties: ["key1||value_a","key1||value_b"] }
          #    { terms: { properties: ["key2||value_a"] }
          # This enforces "and" relation between different property values and "or" relation between same property values
          properties = @properties.map{ |key, value| [key].product(value) }.map do |pair|
            and_filter << { terms: { properties: pair.map { |property| property.join('||') } } }
          end
        end

        sorting = case @sorting
        when 'name_asc'
          [ { 'name.pinyin' => { order: 'asc' } }, { price: { order: 'asc' } }, '_score' ]
        when 'name_desc'
          [ { 'name.pinyin' => { order: 'desc' } }, { price: { order: 'asc' } }, '_score' ]
        when 'price_asc'
          [ { 'price' => { order: 'asc' } }, { 'name.pinyin' => { order: 'asc' } }, '_score' ]
        when 'price_desc'
          [ { 'price' => { order: 'desc' } }, { 'name.pinyin' => { order: 'asc' } }, '_score' ]
        when 'score'
          [ '_score', { 'name.pinyin' => { order: 'asc' } }, { price: { order: 'asc' } } ]
        else
          [ { 'name.pinyin' => { order: 'asc' } }, { price: { order: 'asc' } }, '_score' ]
        end

        # aggregations
        aggregations = {
          price: { stats: { field: 'price' } },
          properties: { terms: { field: 'properties', order: { _count: 'asc' }, size: 1000000 } },
          taxon_ids: { terms: { field: 'taxon_ids', size: 1000000 } }
        }

        # basic skeleton
        result = {
          min_score: 0.1,
          query: { filter: {} },
          sort: sorting,
          # from: from,
          # aggregations: aggregations
        }

        # # add query and filters to filtered
        result[:query] = query
        # # taxon and property filters have an effect on the facets
        # and_filter << { terms: { taxon_ids: taxons } } unless taxons.empty?
        # # only return products that are available
        and_filter << { range: { available_on: { lte: 'now' } } }
        result[:query][:bool][:filter] = { and: and_filter } unless and_filter.empty?
        #
        # # add price filter outside the query because it should have no effect on facets
        if price_min && price_max && (price_min < price_max)
          result[:query][:bool][:filter] = { range: { price: { gte: price_min, lte: price_max } } }
        end

        result
      end
    end



    private

    def property_list
      product_properties.map{|pp| "#{pp.property.name}||#{pp.value}"}
    end
  end
end
