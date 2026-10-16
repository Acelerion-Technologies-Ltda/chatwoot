class Messages::ApiRetryService
  RETRY_TIMEOUT = 5.minutes

  def initialize(message)
    @message = message
  end

  def perform
    @message.with_lock do
      return false unless retryable?
      raise 'API inbox webhook is not configured' if channel.webhook_url.blank?

      retry_request = @message.additional_attributes['api_retry']
      return false if retry_request && Time.iso8601(retry_request.fetch('requested_at')) > RETRY_TIMEOUT.ago

      retry_request = { 'id' => SecureRandom.uuid, 'requested_at' => Time.current.iso8601 }
      @message.update!(additional_attributes: @message.additional_attributes.merge('api_retry' => retry_request))

      # Notify only the channel integration. Replaying the application-wide
      # message-created event would repeat notifications and automations.
      WebhookJob.perform_later(
        channel.webhook_url, @message.webhook_data.merge(event: 'message_created'), :api_inbox_webhook,
        secret: channel.secret, delivery_id: retry_request.fetch('id')
      )
      true
    end
  end

  private

  def retryable?
    @message.failed? && @message.outgoing? && !@message.private? && !@message.content_attributes['deleted']
  end

  def channel
    @message.inbox.channel
  end
end
