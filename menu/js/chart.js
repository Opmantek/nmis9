
$(function($) {
  loadCharts();
});

function loadCharts() {
  for( i = 0; i < window.graphs.length; i++ ) {
    graph_obj = window.graphs[i];
    $.ajax({
      url     : graph_obj.url,
      async   : false,
      dataType: "json",
      type    : 'GET',
      cache   : false,
      success : function(data) {
        drawSummaryGraph(data, graph_obj.span, graph_obj.div, "yAxis0TitleText", "yAxis1TitleText", "pointInterval", "titleText", "toolTipSuffix", false);
      }
    });
  }
}

function drawSummaryGraph(jsonData, renderTo, div, stacking )
{
  data = jsonData.data;
  
  for( i = 0; i < data.length; i++ ) {
    data.selected = true;
  }

  // cleanUpOldGraph(renderTo);
  
  graph = new Highcharts.Chart({
    // $("#"+renderTo).highcharts({
    chart: {      
      renderTo: renderTo,
      plotBackgroundColor: null,
      plotBorderColor: '#346691',
      plotBorderWidth: 2,
      plotShadow: false,
      zoomType: 'x',
      events: {
        selection: function(event) {
          if ( typeof(graph_point_click_event) != "undefined" ) {
            graph_chart_selection(event);
          }
        }
      },
    },
    legend: {
      enabled: true
    },
    rangeSelector : {
      enabled : false
    },
    credits: {
      enabled: false
    },
    xAxis: {
      type: 'datetime',
      maxZoom: 60000,
      title: {
        text: ""
      }
    },
    yAxis: 
    [
      { 
        title: { text: jsonData.yAxis0TitleText },
        showEmpty: true,
        offset: 20,
      },
      { 
        title: { text: jsonData.yAxis1TitleText },
        opposite: true,
        showEmpty: false,
        offset: 20,
      }
    ],
    plotOptions: {      
      series: {        
        showCheckbox: true,
        stacking: stacking,
        marker: {
          enabled: false
        },
        point: {
                events: {
                    click: function() {
                      if ( typeof(graph_point_click_event) != "undefined" ) {
                        graph_point_click_event(this);
                      }
                    }
                }
            }
        // pointStart: pointStart,
        // pointInterval: pointInterval
      }
    },
    title: {
      text: jsonData.titleText
    },
    // subtitle: {
    //         text: jsonData.subTitle,
    //         align: 'right',
    //         x: -10
    //     },
    tooltip: {
      valueDecimals: 0,
      valueSuffix: jsonData.toolTipSuffix,
      shared: true,
    
    },          
    series: data
  }); 
  widthAdjustment = -10;
  // setGraph(renderTo, graph, div, widthAdjustment);
  $("#"+div).append("<pre>"+jsonData.subTitle+"</pre>")
  // return graph;
}

function setGraph(renderTo, graph, div, widthAdjustment)
{
  if( typeof renderTo === "object" ) 
  {
    renderTo = renderTo.id;
  }
  if( window["graphs"] === undefined )
  {
    window["graphs"] = {};
  }
  window["graphs"][renderTo+"Object"] = graph;
  $(graph).data("enclosingDiv", div );
  $(graph).data("renderTo", renderTo );
  $(graph).data("widthAdjustment", widthAdjustment );
}

function cleanUpOldGraph(id)
{  
  if( typeof(window[id]) == "object" )
  {  
    // window[id].destroy();
  }
}
