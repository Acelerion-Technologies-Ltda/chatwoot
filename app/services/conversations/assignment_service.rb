class Conversations::AssignmentService
  def initialize(conversation:, assignee_id:, assignee_type: nil)
    @conversation = conversation
    @assignee_id = assignee_id
    @assignee_type = assignee_type
  end

  def perform
    agent_bot_assignment? ? assign_agent_bot : assign_agent
  end

  private

  attr_reader :conversation, :assignee_id, :assignee_type

  def assign_agent
    return clear_assignee if assignee_id.blank?
    return unless assignee

    conversation.with_lock do
      if open_on_assignment? && conversation.pending?
        conversation.status = :open
        conversation.waiting_since = Time.current if conversation.waiting_since.blank?
      end
      conversation.assignee = assignee
      conversation.ai_assignee = nil
      conversation.save!
    end
    assignee
  end

  def clear_assignee
    conversation.assignee = nil
    conversation.ai_assignee = nil
    conversation.save!
  end

  def assign_agent_bot
    assign_ai_assignee(agent_bot)
  end

  def open_on_assignment?
    assignee.present? && conversation.ai_assignee_type.present?
  end

  def assign_ai_assignee(ai_assignee)
    return unless ai_assignee

    conversation.with_lock do
      conversation.assignee = nil
      conversation.ai_assignee = ai_assignee
      conversation.save!
    end
    ai_assignee
  end

  def assignee
    @assignee ||= conversation.inbox.assignable_agents.find_by(id: assignee_id)
  end

  def agent_bot
    @agent_bot ||= AgentBot.accessible_to(conversation.account).find_by(id: assignee_id)
  end

  def agent_bot_assignment?
    assignee_type.to_s == 'AgentBot'
  end
end

Conversations::AssignmentService.prepend_mod_with('Conversations::AssignmentService')
