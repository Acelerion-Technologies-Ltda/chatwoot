require 'rails_helper'

describe Conversations::AssignmentService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#perform' do
    context 'when assignee_id is blank' do
      before do
        conversation.update!(assignee: agent, ai_assignee: agent_bot)
      end

      it 'clears both human and bot assignees' do
        described_class.new(conversation: conversation, assignee_id: nil).perform

        conversation.reload
        expect(conversation.assignee_id).to be_nil
        expect(conversation.assignee_agent_bot_id).to be_nil
        expect(conversation.ai_assignee_type).to be_nil
      end

      it 'preserves conversation status' do
        conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)

        described_class.new(conversation: conversation, assignee_id: nil).perform

        expect(conversation.reload.status).to eq('snoozed')
      end
    end

    context 'when assigning a user' do
      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
        conversation.update!(ai_assignee: agent_bot, assignee: nil, status: :pending)
      end

      it 'sets the agent, clears agent bot and opens the conversation' do
        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        conversation.reload
        expect(result).to eq(agent)
        expect(conversation.assignee_id).to eq(agent.id)
        expect(conversation.assignee_agent_bot_id).to be_nil
        expect(conversation.ai_assignee_type).to be_nil
        expect(conversation.status).to eq('open')
      end

      it 'starts the waiting clock when opening a bot-owned pending conversation' do
        conversation.update!(waiting_since: nil)

        freeze_time do
          described_class.new(conversation: conversation, assignee_id: agent.id).perform

          expect(conversation.reload.waiting_since).to eq(Time.current)
        end
      end

      it 'preserves status for ordinary human assignment changes' do
        conversation.update!(ai_assignee: nil, status: :resolved)

        described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(conversation.reload.status).to eq('resolved')
      end

      it 'preserves status when taking over a bot-owned non-pending conversation' do
        conversation.update!(ai_assignee: agent_bot, status: :resolved)

        described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(conversation.reload.status).to eq('resolved')
      end

      it 'does not assign a user outside the inbox' do
        outside_agent = create(:user, account: account, role: :administrator)
        conversation.update!(ai_assignee: nil, assignee: agent)

        result = described_class.new(conversation: conversation, assignee_id: outside_agent.id).perform

        conversation.reload
        expect(result).to be_nil
        expect(conversation.assignee_id).to eq(agent.id)
      end

      it 'assigns the agent unique team when the account setting is enabled' do
        account.update!(auto_assign_agent_unique_team: true)
        unique_team = create(:team, account: account)
        create(:team_member, team: unique_team, user: agent)

        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(result).to eq(agent)
        expect(conversation.reload.assignee_id).to eq(agent.id)
        expect(conversation.team_id).to eq(unique_team.id)
      end

      it 'preserves the current team when the agent has no teams' do
        account.update!(auto_assign_agent_unique_team: true)
        current_team = create(:team, account: account, allow_auto_assign: false)
        conversation.update!(team: current_team)

        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(result).to eq(agent)
        expect(conversation.reload.assignee_id).to eq(agent.id)
        expect(conversation.team_id).to eq(current_team.id)
      end

      it 'preserves the current team when the agent has multiple teams' do
        account.update!(auto_assign_agent_unique_team: true)
        current_team = create(:team, account: account, allow_auto_assign: false)
        create_list(:team, 2, account: account).each do |team|
          create(:team_member, team: team, user: agent)
        end
        conversation.update!(team: current_team)

        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(result).to eq(agent)
        expect(conversation.reload.assignee_id).to eq(agent.id)
        expect(conversation.team_id).to eq(current_team.id)
      end

      it 'keeps a missing team missing when the agent has multiple teams' do
        account.update!(auto_assign_agent_unique_team: true)
        create_list(:team, 2, account: account).each do |team|
          create(:team_member, team: team, user: agent)
        end

        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(result).to eq(agent)
        expect(conversation.reload.assignee_id).to eq(agent.id)
        expect(conversation.team_id).to be_nil
      end
    end

    context 'when assigning an agent bot' do
      let(:service) do
        described_class.new(
          conversation: conversation,
          assignee_id: agent_bot.id,
          assignee_type: 'AgentBot'
        )
      end

      it 'sets the agent bot, clears human assignee and preserves the open status' do
        conversation.update!(assignee: agent, ai_assignee: nil, status: :open)

        result = service.perform

        conversation.reload
        expect(result).to eq(agent_bot)
        expect(conversation.assignee_agent_bot_id).to eq(agent_bot.id)
        expect(conversation.ai_assignee_type).to eq('AgentBot')
        expect(conversation.assignee_id).to be_nil
        expect(conversation.status).to eq('open')
      end

      it 'preserves a resolved conversation status' do
        conversation.update!(status: :resolved)

        service.perform

        expect(conversation.reload.status).to eq('resolved')
      end

      it 'preserves a snoozed conversation and its snooze timestamp' do
        conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)
        snoozed_until = conversation.reload.snoozed_until

        service.perform

        conversation.reload
        expect(conversation.status).to eq('snoozed')
        expect(conversation.snoozed_until).to eq(snoozed_until)
      end
    end
  end
end
