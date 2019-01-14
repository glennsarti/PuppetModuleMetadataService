require 'json'
require 'aws-sdk-s3'
require './helpers'

require 'pp'

S3_CLIENT = Aws::S3::Client.new

def process(event:, context:)
  result = []
  #puts "event\n#{pp(event)}\ncontext\n#{pp(context)}\n"

  event['Records'].each do |event_record|
    body = JSON.parse(event_record['body'])
    body['Records'].each do |message|
      s3_bucket = message['s3']['bucket']['name']
      s3_key = message['s3']['object']['key']

      # Check if the S3 Object has the correct tag
      object = { bucket: s3_bucket, key: s3_key }
      begin
        s3objecttags = S3_CLIENT.get_object_tagging(object)
        tags = process_s3tags(s3objecttags.tag_set)
        unless (tags['createrequest'] == 'true')
          result << "#{s3_key} is not a create request"
          next
        end
      rescue RuntimeException => ex
        # Do nothing don't care.
        puts "Error getting tags for #{object}: #{ex}"
        next
      end

      begin
        # Read in the S3 object to get the request metadata
        s3object = S3_CLIENT.get_object(object)
        s3content = JSON.parse(s3object.body.read)
      rescue RuntimeException => ex
        # Do nothing don't care.
        puts "Error content for #{object}: #{ex}"
        next
      end

      module_author = s3content['metadata']['module_author']
      module_name = s3content['metadata']['module_name']
      module_version = s3content['metadata']['module_version']
      # puts module_author
      # puts module_name
      # puts module_version

      # TODO Actually get the content.  For now, pretend
      module_metadata = {
        readme:               "readme",
        metadatajson_content: "raw metadata.json file",
        functions:            [],
        classes:              [],
        types:                []
      }

      # Save the module_metadata and remove createrequest tag
      s3content['metadata']['extracted_timestamp'] = Time.now.getutc.to_s
      s3content['content'] = module_metadata
      request = {
        body: JSON.generate(s3content),
        bucket: s3_bucket,
        key: s3_key,
        tagging: "",
      }
      resp = S3_CLIENT.put_object(request)
    end
  end

  result
end


# Example Event Body
# {
#   "Records": [{
#     "eventVersion": "2.1",
#     "eventSource": "aws:s3",
#     "awsRegion": "us-east-1",
#     "eventTime": "2019-01-10T12:47:04.367Z",
#     "eventName": "ObjectCreated:Put",
#     "userIdentity": {
#       "principalId": "abc123"
#     },
#     "requestParameters": {
#       "sourceIPAddress": "180.150.82.128"
#     },
#     "responseElements": {
#       "x-amz-request-id": "398DC23C7DB66AB1",
#       "x-amz-id-2": "M3QMF3USnSwuMu4GbOdorlqp3i/vX5Ix2NPP8XNsb/QBSRs34vWMTilNfNabpnYEbudUsyAM8Os="
#     },
#     "s3": {
#       "s3SchemaVersion": "1.0",
#       "configurationId": "e2aa871d-9340-471d-9073-f85e62de85bf",
#       "bucket": {
#         "name": "bucketname",
#         "ownerIdentity": {
#           "principalId": "abc123"
#         },
#         "arn": "arn:aws:s3:::bucketname"
#       },
#       "object": {
#         "key": "filename",
#         "size": 887,
#         "eTag": "7a21fd660bc8cb1626bb837ac5c947f6",
#         "versionId": "J2d5ENlOFlbhyv75coTXceQBwd8JgIhn",
#         "sequencer": "005C373EC8504B11DA"
#       }
#     }
#   }]
# }
