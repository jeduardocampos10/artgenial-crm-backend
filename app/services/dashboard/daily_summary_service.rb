# frozen_string_literal: true

module Dashboard
  # Deterministic, on-demand and aggregate-only operational summary.
  # The caller supplies already-authorized scopes; no message content or PII is returned.
  class DailySummaryService
    DEFAULT_TIMEZONE = 'America/Sao_Paulo'

    def initialize(user:, pipelines:, date: nil, timezone: nil)
      @user = user
      @pipelines = pipelines
      @timezone = timezone.presence || DEFAULT_TIMEZONE
      @zone = ActiveSupport::TimeZone[@timezone]
      raise ArgumentError, 'Invalid timezone' unless @zone

      @date = date.present? ? Date.iso8601(date.to_s) : Time.current.in_time_zone(@zone).to_date
      @range = day_range
    rescue Date::Error
      raise ArgumentError, 'Invalid date. Use YYYY-MM-DD'
    end

    def call
      conversations = accessible_conversations
      pipeline_items = PipelineItem.where(pipeline_id: @pipelines.select(:id))
      tasks = PipelineTask.joins(:pipeline_item).where(pipeline_items: { pipeline_id: @pipelines.select(:id) })

      conversation_data = build_conversations(conversations)
      task_data = build_tasks(tasks)

      {
        date: @date.iso8601,
        timezone: @timezone,
        generated_at: Time.current.iso8601,
        conversations: conversation_data,
        messages: build_messages(conversations),
        pipeline: build_pipeline(pipeline_items),
        tasks: task_data,
        highlights: build_highlights(conversation_data, task_data)
      }
    end

    private

    def day_range
      beginning = @zone.local(@date.year, @date.month, @date.day).utc
      ending = beginning + 1.day
      beginning...ending
    end

    def accessible_conversations
      Conversation.where(inbox_id: @user.assigned_inboxes.select(:id))
    end

    def build_conversations(scope)
      {
        created: scope.where(created_at: @range).count,
        resolved: ReportingEvent.where(name: 'conversation_resolved', inbox_id: @user.assigned_inboxes.select(:id),
                                        created_at: @range).distinct.count(:conversation_id),
        open_now: scope.open.count,
        unattended_now: scope.open.unattended.count,
        unassigned_now: scope.open.unassigned.count
      }
    end

    def build_messages(conversations)
      messages = Message.where(conversation_id: conversations.select(:id), created_at: @range)
      { incoming: messages.incoming.count, outgoing: messages.outgoing.count }
    end

    def build_pipeline(items)
      created = items.where(created_at: @range)
      {
        new_leads: created.where.not(contact_id: nil).count,
        new_deals: created.where.not(conversation_id: nil).count,
        new_items: created.count,
        active_now: items.active.count,
        completed_today: items.where(completed_at: @range).count
      }
    end

    def build_tasks(tasks)
      open_tasks = tasks.where(status: %i[pending overdue])
      {
        due_today: open_tasks.where(due_date: @range).count,
        overdue: open_tasks.where('pipeline_tasks.due_date < ?', @range.begin).count,
        completed_today: tasks.where(completed_at: @range).count,
        urgent_open: open_tasks.where(priority: :urgent).count
      }
    end

    def build_highlights(conversations, tasks)
      highlights = []
      if conversations[:unattended_now].positive?
        highlights << highlight('warning', 'unattended_conversations', "#{conversations[:unattended_now]} conversa(s) sem atendimento")
      end
      if tasks[:overdue].positive?
        highlights << highlight('warning', 'overdue_tasks', "#{tasks[:overdue]} tarefa(s) atrasada(s)")
      end
      if tasks[:urgent_open].positive?
        highlights << highlight('critical', 'urgent_tasks', "#{tasks[:urgent_open]} tarefa(s) urgente(s) aberta(s)")
      end
      highlights << highlight('info', 'no_operational_alerts', 'Nenhum alerta operacional no resumo') if highlights.empty?
      highlights
    end

    def highlight(kind, code, text)
      { kind: kind, code: code, text: text }
    end
  end
end
