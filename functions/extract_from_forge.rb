require 'json'
require 'aws-sdk-s3'
require './helpers'
require 'tmpdir'
require 'fileutils'

require './vendor/pes/lib/puppet-editor-services/version'

require 'pp'

S3_CLIENT = Aws::S3::Client.new

def puppet_command
  "ruby " + File.join(File.dirname(__FILE__), 'vendor', 'bundle', 'ruby', '2.5.0', 'bin', 'puppet')
end

def process(event:, context:)
  result = []
  #puts "event\n#{pp(event)}\ncontext\n#{pp(context)}\n"

  # Puppet requires a HOME env var but Lambda doesn't have one
  ENV['HOME'] = '/var/task' if ENV['HOME'].nil?

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
      rescue RuntimeError => ex
        # Do nothing don't care.
        puts "Error getting tags for #{object}: #{ex}"
        next
      end

      begin
        # Read in the S3 object to get the request metadata
        s3object = S3_CLIENT.get_object(object)
        s3content = JSON.parse(s3object.body.read)
      rescue RuntimeError => ex
        # Do nothing don't care.
        puts "Error content for #{object}: #{ex}"
        next
      end

      module_author = s3content['metadata']['module_author']
      module_name = s3content['metadata']['module_name']
      module_version = s3content['metadata']['module_version']
      module_metadata = {}

      # puts module_author
      # puts module_name
      # puts module_version

      # Extract the metadata if we can succesfully download
      module_metadata = {}
      begin
        tmp_path = Dir.mktmpdir
        create_skeleton_puppet_filesystem(tmp_path)
        module_metadata = sidecar_extraction(module_name, tmp_path) if download_module(module_author, module_name, module_version, tmp_path)
      ensure
        FileUtils.remove_dir(tmp_path, true)
      end

      # Save the module_metadata and remove createrequest tag
      s3content['metadata']['extracted_timestamp'] = Time.now.getutc.to_s
      s3content['metadata']['editor_services_version'] = PuppetEditorServices.version
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

def module_path(root_dir)
  File.join(root_dir, 'environments', 'extract', 'modules')
end

def confdir_path(root_dir)
  File.join(root_dir, 'confdir')
end

def vardir_path(root_dir)
  File.join(root_dir, 'cache')
end

def puppet_editor_service_path
  @pes_path ||= File.join(File.dirname(__FILE__), 'vendor', 'pes')
end

def create_skeleton_puppet_filesystem(root_path)
  Dir.mkdir(vardir_path(root_path))
  Dir.mkdir(confdir_path(root_path))
  Dir.mkdir(File.join(root_path, 'environments'))
  Dir.mkdir(File.join(root_path, 'environments', 'extract'))
  Dir.mkdir(module_path(root_path))
  Dir.mkdir(File.join(root_path, 'logdir'))

  pupconf = <<-PUPCONF
  # Text fixture puppet.conf which redirects all Puppet configuration into the
  # fixtures directory
  [main]
  environment = extract
  environmentpath = $codedir/environments
  codedir = $vardir/..
  logdir = $vardir/../logdir
  PUPCONF
  File.write(File.join(confdir_path(root_path), 'puppet.conf'), pupconf, mode: 'wb:utf-8')
end

def download_module(module_author, module_name, module_version, root_dir)
  puts "Downloading module #{module_author}-#{module_name} version #{module_version} ..."

  cmd = "#{puppet_command} module install #{module_author}-#{module_name} --version #{module_version} --modulepath #{module_path(root_dir)} --ignore-dependencies --force --confdir #{confdir_path(root_dir)} --vardir #{vardir_path(root_dir)}"
  puts "Downloading the module using command: #{cmd}"
  proc_out, proc_err, status = Open3.capture3(cmd)

  unless status.exitstatus.zero?
    puts "Download returned error code #{status.exitstatus}"
    puts "STDOUT:\n#{proc_out}"
    puts "STDERR:\n#{proc_err}"
    return false
  end

  puts "Succesfully downloaded"
  puts "STDOUT:\n#{proc_out}"
  true
end

def sidecar_extraction(module_name, root_dir)
  result = {
    metadata_file: nil,
    functions:     [],
    classes:       [],
    types:         []
  }
  workspace_path = File.join(module_path(root_dir), module_name)

  # TODO Multithread it instead of serial

  sidecar_settings = "--local-workspace=#{workspace_path} --puppet-settings=--vardir,#{vardir_path(root_dir)},--confdir,#{confdir_path(root_dir)}"

  cmd = "ruby #{File.join(puppet_editor_service_path, 'puppet-languageserver-sidecar')} --action=workspace_classes #{sidecar_settings}"
  puts "Extracting classes using: #{cmd}"
  classes_string, proc_err, status = Open3.capture3(cmd)
  unless status.exitstatus.zero?
    puts "Extracting classes  returned error code #{status.exitstatus}"
    puts "STDERR:\n#{proc_err}"
    classes_string = "[]"
  end

  cmd = "ruby #{File.join(puppet_editor_service_path, 'puppet-languageserver-sidecar')} --action=workspace_functions #{sidecar_settings}"
  puts "Extracting functions using: #{cmd}"
  functions_string, proc_err, status = Open3.capture3(cmd)
  unless status.exitstatus.zero?
    puts "Extracting functions returned error code #{status.exitstatus}"
    puts "STDERR:\n#{proc_err}"
    functions_string = "[]"
  end

  cmd = "ruby #{File.join(puppet_editor_service_path, 'puppet-languageserver-sidecar')} --action=workspace_types #{sidecar_settings}"
  puts "Extracting types using: #{cmd}"
  types_string, proc_err, status = Open3.capture3(cmd)
  unless status.exitstatus.zero?
    puts "Extracting types returned error code #{status.exitstatus}"
    puts "STDERR:\n#{proc_err}"
    types_string = "[]"
  end
  puts types_string

  result[:classes] = sanitise_extract(classes_string)
  result[:functions] = sanitise_extract(functions_string)
  result[:types] = sanitise_extract(types_string)

  # Add metadata.JSON information
  metadata_filename = File.join(workspace_path, 'metadata.json')
  if File.exists?(metadata_filename)
    File.open(metadata_filename, "rb:utf-8") do |f|
      result[:metadata_file] = JSON.parse(f.read)
    end
  end

  result
end

def sanitise_extract(value)
  # Convert strings to objects
  # Strip callingsource, source and line numbers
  object = JSON.parse(value)

  remove_items = ['source', 'calling_source', 'line', 'char']

  object.each do |child|
    child.reject! { |k| remove_items.include?(k) }
  end

  object
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
