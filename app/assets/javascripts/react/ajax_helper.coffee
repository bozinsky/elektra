class @ReactAjaxHelper
  constructor: (rootUrl) ->
    @rootUrl = rootUrl
    unless @rootUrl
      l = window.location
      @rootUrl = "#{l.protocol}//#{l.host}/#{l.pathname}"

  @buildUrl: (root,path) ->
    if path.indexOf('http')>-1
      return path
    else
      return root+path

  @request: (url, method, options={}) ->
    url = url.replace(/([^:]\/)\/+/g, "$1")
    $.ajax
      url: url
      method: method
      dataType: options['dataType'] || 'json'
      data: options['data']
      success: options['success']
      error: options['error']
      complete: ( jqXHR, textStatus) ->
        redirectToUrl = jqXHR.getResponseHeader('Location')
        if redirectToUrl # url is presented
          # Redirect to url
          currentUrl = encodeURIComponent(window.location.href)
          redirectToUrl = redirectToUrl.replace(/after_login=(.*)/g,"after_login=#{currentUrl}")
          window.location = redirectToUrl
        else
          options['complete'](jqXHR, textStatus) if options["complete"]

  get: (path,options={}) -> ReactAjaxHelper.request(ReactAjaxHelper.buildUrl(@rootUrl,path),'GET',options)
  post: (path,options={}) -> ReactAjaxHelper.request(ReactAjaxHelper.buildUrl(@rootUrl,path),'POST',options)
  put: (path,options={}) -> ReactAjaxHelper.request(ReactAjaxHelper.buildUrl(@rootUrl,path),'PUT',options)
  delete: (path,options={}) -> ReactAjaxHelper.request(ReactAjaxHelper.buildUrl(@rootUrl,path),'DELETE',options)
