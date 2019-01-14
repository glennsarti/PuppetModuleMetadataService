require 'pp'

def process_s3tags(tag_set)
  result = {}

  tag_set.each { |item| result[item.key] = item.value }

  result
end
