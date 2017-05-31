namespace :spree_elasticsearch do
  desc "Load all products into the index."
  task :load_products => :environment do
    unless Elasticsearch::Model.client.indices.exists index: Spree::ElasticsearchSettings.index
      Elasticsearch::Model.client.indices.create \
        index: Spree::ElasticsearchSettings.index,
        body: {
          settings: {
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
          },
          mappings: Spree::Product.mappings.to_hash }
    end
    Spree::Product.__elasticsearch__.import
  end

end