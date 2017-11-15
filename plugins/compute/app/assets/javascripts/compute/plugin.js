//= require_tree .

compute.clear_graph = function(ID) {
    // cleanup left overs
    // http://stackoverflow.com/questions/22452112/nvd3-clear-svg-before-loading-new-chart
    // http://stackoverflow.com/questions/28560835/issue-with-useinteractiveguideline-in-nvd3-js
    // https://github.com/Caged/d3-tip/issues/133
    d3.selectAll("svg > *").remove();
    d3.select("#"+ID)
      .on("mousemove", null)
      .on("mouseout", null)
      .on("dblclick", null)
      .on("click", null);
    d3.select(".nvtooltip").remove();
    
    $('#'+ID).empty();
};

compute.render_graph = function(ID,DATA) {
    
  // check that we have a valid data object
  if(typeof(DATA) != "object") {
    compute.no_data(ID);
  }

  nv.addGraph(function() {

    // config x and y Axis
    var chart = nv.models.lineChart()
                  .x(function(d) { return d[0] })
                  .y(function(d) { return parseInt(d[1]) })
                  .useInteractiveGuideline(true); 
     // https://stackoverflow.com/questions/19459687/understanding-nvd3-x-axis-date-format
     chart.xAxis
        .tickFormat(function(d) {
            return d3.time.format('%H:%M')(new Date(d*1000))
          });
          
    chart.margin({"left":30,"right":30,"top":5,"bottom":50});

    // create graph
    d3.select('#'+ID)
      .datum(DATA)
      .transition().duration(500)
      .call(chart)
      ;

    nv.utils.windowResize(chart.update);
    return chart;
  });
  
};

compute.no_data = function(ID) {
  $('#'+ID).html('<text class="nvd3 nv-noData" dy="-.7em" style="text-anchor: middle;" x="434" y="100"}>No Data</text>');
}