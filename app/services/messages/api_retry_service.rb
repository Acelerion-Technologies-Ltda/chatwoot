class Messages::ApiRetryService
  RETRY_TIMEOUT = 5.minutes

  def initialize(message)
    @message = message
  end

  def perform
    @message.with_lock do
      return false unless retryable?
      raise 'Message delivery webhook is not configured' unless delivery_configured?

      retry_request = @message.additional_attributes['api_retry']
      return false if retry_request && Time.iso8601(retry_request.fetch('requested_at')) > RETRY_TIMEOUT.ago

      retry_request = { 'id' => SecureRandom.uuid, 'requested_at' => Time.current.iso8601 }
      @message.update!(additional_attributes: @message.additional_attributes.merge('api_retry' => retry_request))

      # Notify the configured delivery webhooks. Replaying the application-wide
      # message-created event would repeat notifications and automations.
      event = Events::Base.new(Events::Types::MESSAGE_CREATED, Time.current, message: @message)
      WebhookListener.instance.message_created(event)
      AgentBotListener.instance.message_created(event)
      true
    end
  end

  private

  def retryable?
    @message.failed? && @message.outgoing? && !@message.private? && !@message.content_attributes['deleted']
  end

  def delivery_configured?
    return true if channel.webhook_url.present?
    return true if agent_bot_configured?

    account = @message.account
    account.api_and_webhooks_enabled? && account.webhooks.account_type.any? { |webhook| webhook.subscriptions.include?('message_created') }
  end

  def agent_bot_configured?
    inbox = @message.inbox
    conversation = @message.conversation
    bots = inbox.agent_bot_inbox&.active? ? [inbox.agent_bot] : []
    bots << conversation.ai_assignee if conversation.assignee_type == 'AgentBot'
    bots.compact.any? { |bot| bot.outgoing_url.present? }
  end

  def channel
    @message.inbox.channel
  end
end
