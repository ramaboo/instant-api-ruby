require "litmus/instant/version"
require "httparty"
require "uri"
require "cgi"

module Litmus
  class Instant
    include HTTParty

    base_uri "https://instant-api.litmus.com/v1"

    headers "Content-Type" => "application/json"
    headers "Accept"       => "application/json"

    class Error < StandardError; end
    class ApiError < Error; end
    class RequestError < ApiError; end
    class AuthenticationError < ApiError; end
    class AuthorizationError < ApiError; end
    class InvalidOAuthToken < AuthenticationError; end
    class InvalidOAuthScope < AuthorizationError; end
    class InactiveUserError < AuthorizationError; end

    class ServiceError < ApiError; end
    class TimeoutError < ApiError; end
    class NotFound < ApiError; end
    class NetworkError < Error; end

    class << self
      # HTTParty doesn't favour exceptions, we do, so we wrap its methods to
      # give us what we want
      %i{get post patch put delete move copy head options}.each do |method|
        alias_method :"#{method}_without_raise", method

        define_method method do |*args|
          begin
            response = send(:"#{method}_without_raise", *args)
          rescue SocketError, Timeout::Error, Errno::EINVAL, Errno::ECONNRESET,
                   EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
                   Net::ProtocolError => e
            raise NetworkError, e.message
          rescue HTTParty::Error
            raise Error, e.message
          end
          raise_on_failure(response)
        end
      end
    end

    # This allows us to create API Client instances, useful primarily with
    # OAuth, to set a token for each authorized user in a thread safe manner
    # All the class methods on `Instant` are made available on the instance
    class Client
      class << self
        def new(oauth_token: nil, api_key: nil)
          Class.new(Instant) do |klass|
            extend Forwardable

            def_delegators(
              :"self.class",
              *(Litmus::Instant.methods - Object.methods)
            )

            klass.oauth_token = oauth_token if oauth_token
            klass.api_key = api_key if api_key
          end.new
        end
      end
    end

    # Get or set your Instant API key
    # @return [String]
    def self.api_key(key = nil)
      self.api_key = key if key
      @key
    end

    # Set your Instant API key
    def self.api_key=(key)
      self.default_options.delete :basic_auth
      basic_auth key, "" if key
      @key = key
    end

    # Get or set a global OAuth token to use
    # This is *not* thread safe, if you intend to authorize multiple end users
    # within the same application use
    #
    #     Litmus::Instant::Client.new(oauth_token: "XXX")
    #
    # @return [String]
    def self.oauth_token(token = nil)
      self.api_token = token if token
      @token
    end

    # Set an OAuth token to be used globally
    # This is *not* thread safe, if you intend to authorize multiple end users
    # within the same application use
    #
    #     Litmus::Instant::Client.new(oauth_token: "XXX")
    #
    def self.oauth_token=(token)
      self.default_options[:headers].delete "Authorization"
      self.headers("Authorization" => "Bearer #{token}") if token
      @token = token
    end

    # Describe an email’s content and metadata and, in exchange, receive an
    # +email_guid+ required to capture previews of it
    #
    # We intend these objects to be treated as lightweight. Once uploaded,
    # emails can't be modified. Obtain a new +email_guid+ each time changes need
    # to be reflected.
    #
    # The uploaded email has a limited lifespan. As a result, a new +email_guid+
    # should be obtained before requesting new previews if more than a day has
    # passed since the last upload.
    #
    # At least one of +:html_text+, +:plain_text+, +:raw_source+ must be
    # provided.
    #
    # @param [Hash] email
    # @option email [String] :html_text
    # @option email [String] :plain_text
    # @option email [String] :subject
    # @option email [String] :from_address
    # @option email [String] :from_display_name
    # @option email [String] :raw_source
    #   This field provides an alternative approach to defining the email and
    #   so is only valid in the absence of all the fields above
    # @option email [String] :end_user_id A unique identifier for your end
    #   users. When provided, we use this to partition your usage data.
    #   See https://litmus.com/partners/api/documentation/instant/03-identifying-end-users/
    # @option email [Array<Hash>]  :configurations
    #   An array of capture capture configuration hashes
    #   This allows pre-requesting previews that should be captured as soon as
    #   possible. This can be a useful performance optimisation.
    #   See +.prefetch_previews+ for further detail on format.
    #
    # @param [String] token
    #   optional OAuth authentication token when calling on behalf of a Litmus
    #   user. This will be different for each OAuth connected user.
    #
    # @return [Hash] the response containing the +email_guid+ and also
    #   confirmation of +end_user_id+ and +configurations+ if provided
    def self.create_email(email)
      post("/emails", body: email.to_json)
    end

    # List supported email clients
    # @return [Array<String>] array of email client names
    def self.clients
      get "/clients"
    end

    # List supported email client configurations
    # @return [Hash] hash keyed by email client name, values are a Hash with the
    #   the keys +orientation_options+ and +images_options+
    def self.client_configurations
      get "/clients/configurations"
    end

    # Request a preview
    #
    # This triggers the capture of a preview. The method blocks until capture
    # completes. The response contains URLs for each of the image sizes
    # available. A further request will be needed to obtain actual image data
    # from one of the provided URLs.
    #
    # @param email_guid [String]
    # @param client [String]
    # @param options [Hash]
    # @option options [String] :images +allowed+ (default) or +blocked+
    # @option options [String] :orientation +horizontal+ or +vertical+ (default)
    #
    # @return [Hash] a hash mapping the available capture sizes to their
    #   corresponding URLs
    def self.get_preview(email_guid, client, options = {})
      query = URI.encode_www_form(options)
      get "/emails/#{email_guid}/previews/#{client}?#{query}"
    end

    # Pre-request a set of previews before download
    #
    # This method is provided as an optional performance enhancement, typically
    # useful before embedding a set of previews within a browser, where
    # connection limits might otherwise delay the start of capture of some
    # previews.
    #
    # The method does not block while capture occurs, a response is returned
    # immediately.
    #
    # Note that should capture failure occur for a preview, it will only be
    # discovered when the preview is later requested. Request errors, for
    # instance attempting to prefetch an invalid client, will result raise
    # normally howver.
    #
    # @param email_guid [String]
    # @param configurations [Array<Hash>]An array of capture capture configurations
    #   Each configuration Hash must have a +:client+ key, and optional
    #   +:orientation+ and +images+ keys
    #
    # @return [Hash] confirmation of the configurations being captured
    def self.prefetch_previews(email_guid, configurations)
      post "/emails/#{email_guid}/previews/prefetch", body: { configurations: configurations }.to_json
    end

    # Construct a preview image URL ready for download
    #
    # The generated URLs can be embedded directly within a client application,
    # for instance with the +src+ tag of an HTML +img+ tag.
    #
    # This is also useful for downloading a capture in a single step, rather
    # than calling +.get_preview+ then making a follow up request to retrieve
    # the image data.
    #
    # @param [String] email_guid
    # @param [String] client
    # @param [Hash] options
    # @option options [String] :capture_size +full+ (default), +thumb+ or +thumb450+
    # @option options [String] :images +allowed+ (default) or +blocked+
    # @option options [String] :orientation +horizontal+ or +vertical+ (default)
    # @option options [Boolean] :fallback by default errors during capture
    #   redirect to a fallback image, setting this to +false+ will mean that
    #   GETs to the resulting URL will receive HTTP error responses instead
    # @option options [String] :fallback_url a custom fallback image to display
    #   in case of errors. This must be an absolute URL and have a recognizable
    #   image extension. Query parameters are not supported. The image should be
    #   accessible publicly without the need for authentication.
    #
    # @return [String] the preview URL, domain sharded by the client name
    def self.preview_image_url(email_guid, client, options = {})
      # We'd use Ruby 2.x keyword args here, but it's more useful to preserve
      # compatibility for anyone stuck with ruby < 2.x
      capture_size = options.delete(:capture_size) || "full"

      if options.keys.length > 0
        if options[:fallback_url]
          options[:fallback_url] = CGI.escape(options[:fallback_url])
        end
        query = URI.encode_www_form(options)
        "#{sharded_base_uri(client)}/emails/#{email_guid}/previews/#{client}/#{capture_size}?#{query}"
      else
        "#{sharded_base_uri(client)}/emails/#{email_guid}/previews/#{client}/#{capture_size}"
      end
    end

    #
    # Private ==================================================================
    #

    # This deliberately allows for multiple authentication challenges within
    # WWW-Authenticate
    BEARER_REGEX = /Bearer realm=\"([^\"]*)\"\, error=\"(?<name>[^\"]*)\"\, error_description=\"(?<description>[^\"]*)\"/

    # This avoids browser per domain connection limits
    def self.sharded_base_uri(client)
      # only shard where it's supported
      if base_uri =~ /\/\/instant-api/
        base_uri.gsub("://","://#{client}.")
      else
        base_uri
      end
    end

    def self.raise_on_failure(response)
      unless response.success?
        message = response["description"] || ""

        bearer_error = extract_bearer_error(response.headers)
        raise bearer_error if bearer_error

        raise AuthenticationError.new(message) if response.code == 401
        raise AuthorizationError.new(message)  if response.code == 403
        raise RequestError.new(message)        if response.code == 400
        raise NotFound.new(message)            if response.code == 404
        raise TimeoutError.new(message)        if response.code == 504
        raise ServiceError.new(message)        if response.code == 500

        # For all other errors
        raise ApiError.new(message)
      end

      response
    end

    def self.extract_bearer_error(headers)
      matches = headers["WWW-Authenticate"] &&
                headers["WWW-Authenticate"].match(BEARER_REGEX)

      return unless matches

      name = matches[:name]
      message = matches[:description]

      klass = case name
              when "invalid_token" then InvalidOAuthToken
              when "invalid_scope" then InvalidOAuthScope
              when "inactive_user" then InactiveUserError
              end

      klass && klass.new(message)
    end

    private_constant :BEARER_REGEX
    private_class_method :sharded_base_uri, :raise_on_failure, :extract_bearer_error
  end
end
