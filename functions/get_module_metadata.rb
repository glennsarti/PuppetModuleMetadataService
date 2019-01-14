require 'json'
require 'aws-sdk-s3'
require './helpers'
require 'pp'

S3_CLIENT = Aws::S3::Client.new

def process(event:, context:)
  #puts "event\n#{pp(event)}\ncontext\n#{pp(context)}\n"

  s3_bucket = ENV['S3Bucket']

  return { statusCode: 400 } if event['queryStringParameters'].nil?
  return { statusCode: 400 } if event['queryStringParameters']['author'].nil?
  return { statusCode: 400 } if event['queryStringParameters']['name'].nil?
  return { statusCode: 400 } if event['queryStringParameters']['version'].nil?

  module_author = event['queryStringParameters']['author']
  module_name = event['queryStringParameters']['name']
  module_version = event['queryStringParameters']['version']

  # puts module_author
  # puts module_name
  # puts module_version

  # TODO verify parameters are correct e.g. valid author,name and version

  s3_key = module_author + '-' + module_name + '-' + module_version

  # Check if the object is in S3, and has actually been extracted
  object = { bucket: s3_bucket, key: s3_key }
  begin
    s3object = S3_CLIENT.get_object(object)
    s3objecttags = S3_CLIENT.get_object_tagging(object)
    tags = process_s3tags(s3objecttags.tag_set)
    if (tags['createrequest'] == 'true')
      return { statusCode: 202, body: JSON.generate("Already submitted for extraction") }
    end

    s3content = s3object.body.read
    return { statusCode: 200, body: s3content }
  rescue Aws::S3::Errors::NoSuchKey
    # The object does not exist so queue it up to be created.
  end

  # Create an S3 object with tagging for the extract function
  body = {
    metadata: {
      request_timestamp: Time.now.getutc.to_s,
      module_author:     module_author,
      module_name:       module_name,
      module_version:    module_version,
    },
    content: {
      readme: "",
      metadata_json: { },
      classes: [ ],
      functions: [ ],
      types: [ ]
    }
  }
  request = {
    body: JSON.generate(body),
    bucket: s3_bucket,
    key: s3_key,
    tagging: "createrequest=true",
  }
  #resp = S3_CLIENT.put_object(request)

  { statusCode: 202, body: JSON.generate(body) }
end

# Example event from API Gateway
# {
#   "resource" => "/module",
#   "path" => "/module",
#   "httpMethod" => "GET",
#   "headers" => nil,
#   "multiValueHeaders" => nil,
#   "queryStringParameters" => {
#     "author" => "puppetlabs", "name" => "stdlib", "version" => "5.0.2"
#   },
#   "multiValueQueryStringParameters" => {
#     "author" => ["puppetlabs"], "name" => ["stdlib"], "version" => ["5.0.2"]
#   },
#   "pathParameters" => nil,
#   "stageVariables" => nil,
#   "requestContext" => {
#     "path" => "/module",
#     "accountId" => "abc123user",
#     "resourceId" => "uyxxal",
#     "stage" => "test-invoke-stage",
#     "domainPrefix" => "testPrefix",
#     "requestId" => "c54f4728-17e4-11e9-9950-316276e68ca2",
#     "identity" => {
#       "cognitoIdentityPoolId" => nil,
#       "cognitoIdentityId" => nil,
#       "apiKey" => "test-invoke-api-key",
#       "cognitoAuthenticationType" => nil,
#       "userArn" => "arn:aws:iam::abc123user:root",
#       "apiKeyId" => "test-invoke-api-key-id",
#       "userAgent" =>
#       "aws-internal/3 aws-sdk-java/1.11.465 Linux/4.9.124-0.1.ac.198.71.329.metal1.x86_64 OpenJDK_64-Bit_Server_VM/25.192-b12 java/1.8.0_192",
#       "accountId" => "abc123user",
#       "caller" => "abc123user",
#       "sourceIp" => "test-invoke-source-ip",
#       "accessKey" => "key",
#       "cognitoAuthenticationProvider" => nil,
#       "user" => "abc123user"
#     },
#     "domainName" => "testPrefix.testDomainName",
#     "resourcePath" => "/module",
#     "httpMethod" => "GET",
#     "extendedRequestId" => "TfP9dFmPoAMFg8A=",
#     "apiId" => "123"
#   },
#   "body" => nil,
#   "isBase64Encoded" => false
# }