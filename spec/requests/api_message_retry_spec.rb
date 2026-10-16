require 'rails_helper'

RSpec.describe 'API inbox message retries', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_api, account: account, webhook_url: 'https://integration.example/retry') }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                     message_type: :outgoing, status: :failed, source_id: 'previous-provider-id',
                     content_attributes: { external_error: 'provider rejected recipient' },
                     additional_attributes: { 'unrelated' => 'preserved' })
  end
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/retry" }
  let(:headers) { agent.create_new_auth_token }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    message
    clear_enqueued_jobs
  end

  it 'notifies the integration while preserving the provider failure and source id' do
    post path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(message.reload).to have_attributes(status: 'failed', external_error: 'provider rejected recipient', source_id: 'previous-provider-id')
    expect(message.additional_attributes['unrelated']).to eq('preserved')
    request_id = message.additional_attributes.dig('api_retry', 'id')
    expect(request_id).to be_present
    expect(WebhookJob).to have_been_enqueued.with(
      channel.webhook_url, hash_including(id: message.id, event: 'message_created', source_id: 'previous-provider-id'), :api_inbox_webhook,
      secret: channel.secret, delivery_id: instance_of(String)
    )
    expect(SendReplyJob).not_to have_been_enqueued
    expect(response.parsed_body['status']).to eq('failed')
  end

  it 'supports the account webhook used by integrations without an inbox webhook' do
    account.enable_features!(:api_and_webhooks)
    channel.update!(webhook_url: nil)
    webhook = create(:webhook, account: account, url: 'https://integration.example/account', subscriptions: ['message_created'])
    clear_enqueued_jobs

    post path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(message.reload).to be_failed
    expect(message.additional_attributes.dig('api_retry', 'id')).to be_present
    expect(WebhookJob).to have_been_enqueued.with(
      webhook.url, hash_including(id: message.id, event: 'message_created'), :account_webhook,
      secret: webhook.secret, delivery_id: instance_of(String)
    )
    expect(SendReplyJob).not_to have_been_enqueued
  end

  it 'retries through the active inbox agent bot while a human owns the conversation' do
    channel.update!(webhook_url: nil)
    bot = create(:agent_bot, account: account, outgoing_url: 'https://integration.example/bot')
    create(:agent_bot_inbox, inbox: inbox, agent_bot: bot, status: :active)
    conversation.update!(assignee: agent, status: :open)
    clear_enqueued_jobs

    post path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(message.reload).to be_failed
    expect(AgentBots::WebhookJob).to have_been_enqueued.with(
      bot.outgoing_url, hash_including(id: message.id, event: 'message_created'), :agent_bot_webhook,
      secret: bot.secret, delivery_id: instance_of(String)
    )
    expect(SendReplyJob).not_to have_been_enqueued
  end

  it 'claims only one pending attempt and allows another after a provider rejection' do
    2.times { post path, headers: headers, as: :json }
    first_id = message.reload.additional_attributes.dig('api_retry', 'id')
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)

    Messages::StatusUpdateService.new(message, 'failed', 'still rejected').perform
    expect(message.reload.additional_attributes).not_to have_key('api_retry')
    clear_enqueued_jobs
    post path, headers: headers, as: :json
    expect(message.reload.additional_attributes.dig('api_retry', 'id')).not_to eq(first_id)
    expect(message.external_error).to eq('still rejected')
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)
  end

  it 'finishes the pending attempt only when the provider status arrives' do
    post path, headers: headers, as: :json
    Messages::StatusUpdateService.new(message.reload, 'sent').perform

    expect(message.reload).to be_sent
    expect(message.external_error).to be_nil
    expect(message.additional_attributes).to eq('unrelated' => 'preserved')
    clear_enqueued_jobs
    post path, headers: headers, as: :json
    expect(WebhookJob).not_to have_been_enqueued
  end

  it 'allows a fresh attempt when an earlier attempt has timed out' do
    post path, headers: headers, as: :json
    first_id = message.reload.additional_attributes.dig('api_retry', 'id')
    travel 6.minutes do
      post path, headers: headers, as: :json
      expect(message.reload.additional_attributes.dig('api_retry', 'id')).not_to eq(first_id)
    end
  end

  it 'keeps the failure when the integration is not configured' do
    channel.update!(webhook_url: nil)
    post path, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(message.reload).to be_failed
    expect(message.external_error).to eq('provider rejected recipient')
    expect(message.additional_attributes).not_to have_key('api_retry')
    expect(WebhookJob).not_to have_been_enqueued
  end

  it 'does not replay private messages' do
    message.update!(private: true)
    clear_enqueued_jobs
    post path, headers: headers, as: :json
    expect(message.reload.additional_attributes).not_to have_key('api_retry')
    expect(WebhookJob).not_to have_been_enqueued
  end
end
