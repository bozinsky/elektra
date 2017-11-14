Metrics::Engine.routes.draw do
  get '/' => 'application#index', as: :index
  get 'maia' => 'application#maia', as: :maia
  get 'server_statistics' => 'application#server_statistics', as: :server_statistics
end
