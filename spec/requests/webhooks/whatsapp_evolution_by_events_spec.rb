# frozen_string_literal: true

require 'rails_helper'

# EVO-2089: com WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS=true, a Evolution posta cada
# evento em /webhooks/whatsapp/evolution/<evento> (ex.: messages-upsert). Antes
# só existia a rota base -> 404 em todos os eventos -> nenhuma mensagem entrava.
# A rota :sub_event roteia para o mesmo process_payload; o nome NAO pode ser
# :event porque, no Rails, path params sobrescrevem os do corpo (o `event` do
# payload, "messages.upsert", seria trocado pelo "messages-upsert" da URL).
RSpec.describe 'Webhooks::Whatsapp Evolution by-events routing', type: :request do
  let(:payload) do
    {
      event: 'messages.upsert',
      instance: 'evo-instance',
      data: {
        key: { remoteJid: '5511999999999@s.whatsapp.net', fromMe: false, id: 'ABC123' },
        message: { conversation: 'oi' }
      }
    }
  end

  let(:webhook_secret) { 'test-evolution-webhook-secret-with-32-bytes' }
  let(:delivery_id) { SecureRandom.uuid }
  let(:token) do
    JWT.encode(
      {
        'iat' => Time.current.to_i,
        'exp' => 5.minutes.from_now.to_i,
        'jti' => delivery_id,
        'app' => 'evolution',
        'action' => 'webhook'
      },
      webhook_secret,
      'HS256'
    )
  end
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  around do |example|
    previous_secret = ENV['EVOLUTION_WEBHOOK_SECRET']
    ENV['EVOLUTION_WEBHOOK_SECRET'] = webhook_secret
    example.run
  ensure
    ENV['EVOLUTION_WEBHOOK_SECRET'] = previous_secret
  end

  before do
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(Redis::Alfred).to receive(:delete)
  end

  it 'aceita a sub-rota autenticada por evento e enfileira o job' do
    post '/webhooks/whatsapp/evolution/messages-upsert', params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
  end

  it 'preserva o event do corpo (o :sub_event da URL nao sobrescreve params[:event])' do
    post '/webhooks/whatsapp/evolution/messages-upsert', params: payload, headers: headers, as: :json

    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later) do |hash|
      h = hash.with_indifferent_access
      expect(h[:event]).to eq('messages.upsert')     # do corpo, intacto
      expect(h[:sub_event]).to eq('messages-upsert') # da URL, apenas informativo
    end
  end

  it 'mantem a rota base funcionando (regressao)' do
    post '/webhooks/whatsapp/evolution', params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
  end

  it 'rejeita entrega sem JWT antes do enqueue' do
    post '/webhooks/whatsapp/evolution', params: payload, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'rejeita JWT sem jti' do
    invalid_token = JWT.encode(
      { 'iat' => Time.current.to_i, 'exp' => 5.minutes.from_now.to_i, 'app' => 'evolution', 'action' => 'webhook' },
      webhook_secret,
      'HS256'
    )

    post '/webhooks/whatsapp/evolution', params: payload,
                                           headers: { 'Authorization' => "Bearer #{invalid_token}" }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'confirma replay autenticado sem enfileirar novamente' do
    allow(Redis::Alfred).to receive(:set).and_return(false)

    post '/webhooks/whatsapp/evolution', params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'ignora awaitResponse e permanece assincrono' do
    expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_now)

    post '/webhooks/whatsapp/evolution', params: payload.merge(awaitResponse: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
  end

  it 'libera a reserva quando a fila recusa o job' do
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later).and_raise(StandardError)

    post '/webhooks/whatsapp/evolution', params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:internal_server_error)
    expect(Redis::Alfred).to have_received(:delete).with(a_string_starting_with('evolution:webhook:delivery:'))
  end
end
