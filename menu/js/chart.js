Highcharts.setOptions({
    global: {
        useUTC: false
    }
});

$(function($) {
  loadCharts();
});

var loadCharts = function(dialogHandle) {
  selector = ".chartDiv"
  if( dialogHandle !== undefined ) {
    selector = "#"+dialogHandle.attr("id")+" "+selector;
  }
  $(selector).each( function() {
    chartDiv = this;
    chartSpan = this.childNodes[0];
    chartUrl = $(this).attr("data-chart-url");
    loadChart(chartUrl, chartSpan, chartDiv);
  });
}

var unLoadCharts = function(dialogHandle) {
  selector = ".chartDiv"
  if( dialogHandle !== undefined ) {
    selector = "#"+dialogHandle.attr("id")+" "+selector;
  }
  $(selector).each( function() {
    chartDiv = this;    
    cleanUpChart(chartDiv);
  });
}
function loadChart(url, chartSpan, chartDiv) {
  if( url === undefined || url == "" ) {
    console.log("url to load chart not defined");
    return;
  }
  $.ajax({
    url     : url,
    async   : false,
    dataType: "json",
    type    : 'GET',
    cache   : false,
    success : function(data) {
      drawChart(data, chartSpan, chartDiv);
    },
    error: function (x, e) {    
      if (x.status == 405 ) {
        // this is essentially a made-up status code that tells us to re-autheticate              
        document.location = document.location.href;
      }
    }
  });
}

function drawChart(jsonData, renderTo, div )
{
  if( jsonData === null ) {
    console.log("Error loading data");
    return;
  }

  data = jsonData.data;
  
  for( i = 0; i < data.length; i++ ) {
    data.selected = true;
  }

  titleText = jsonData.titleText;  
  titleOnClick = $(div).attr("data-title-onclick");
  if( titleOnClick !== undefined ) {
    titleText = "<a href='#' onclick='"+titleOnClick+"'>"+titleText+"</a>";
  }
  chartWidth = $(div).attr("data-chart-width");
  chartHeight = $(div).attr("data-chart-height");

  titleStyle = null;
  itemStyle = null;
  axisStyle = null;
  if( chartWidth <= 400 ) {
    Highcharts.setOptions({
      chart: {
        style: {
          fontFamily: '"Lucida Grande", "Lucida Sans Unicode", Verdana, Arial, Helvetica, sans-serif', // default font
          fontSize: '9px'
        }
      }
    });    
    titleStyle = { fontSize: '10px' };
    itemStyle = {
       cursor: 'pointer',
       color: '#274b6d',
       fontSize: '9px'
    };
    axisStyle = {
      color: '#6D869F',
      fontWeight: 'bold',
      fontSize: '9px'
    };
  }
  else {
    Highcharts.setOptions({
      chart: {
        style: {
          fontFamily: '"Lucida Grande", "Lucida Sans Unicode", Verdana, Arial, Helvetica, sans-serif', // default font
          fontSize: '12px'
        }
      }
    });
    titleStyle = {
      color: '#3E576F',
      fontSize: '16px'
    };
    itemStyle = {
       cursor: 'pointer',
       color: '#274b6d',
       fontSize: '12px'
    };
    axisStyle = {
      color: '#6D869F',
      fontWeight: 'bold'
    };
  }

  cleanUpChart(div);
  
  graph = new Highcharts.Chart({    
    chart: { 
      renderTo: renderTo,
      height: chartHeight,
      width: chartWidth,      
      plotBackgroundColor: null,      
      plotBorderWidth: null,
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
      enabled: true,
      itemStyle: itemStyle
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
      },
      labels : {
        style: axisStyle
      }
    },
    yAxis:
    [
      { 
        title: { text: jsonData.yAxis0TitleText },
        showEmpty: true,
        offset: 20,
        max: jsonData.max,
        min: jsonData.min,
        labels : {
          style: axisStyle
        }
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
        showCheckbox: false,
        stacking: jsonData.stacking,
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
      },
      line : {
        lineWidth : 2
      }
    },
    title: {
      text: titleText,
      useHTML: true,
      style: titleStyle
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
  setChart(renderTo, graph, div, widthAdjustment);  
  $(div).append("<p style='fontSize: \'8px\';'>"+jsonData.subTitle+"</p>")
  return graph;
}

function setChart(renderTo, graph, div, widthAdjustment)
{
  $(div).data("chart", graph );
  $(graph).data("enclosingDiv", div );
  $(graph).data("renderTo", renderTo );
  $(graph).data("widthAdjustment", widthAdjustment );
}

function cleanUpChart(div)
{  
  graph = $(div).data("chart");
  if( graph !== undefined )
  {  
    graph.destroy();
    $(div).data("chart", undefined);
  }
}

$(function($) {
  var waitForFinalEvent = (function () {
    var timers = {};
    return function (callback, ms, uniqueId) {
      if (!uniqueId) {
        uniqueId = "Don't call this twice without a uniqueId";
      }
      if (timers[uniqueId]) {
        clearTimeout (timers[uniqueId]);
      }
      timers[uniqueId] = setTimeout(callback, ms);
    };
  })(); 
  $(window).resize(function () { 
    waitForFinalEvent(function(){
      resizeCharts();            
    }, 1000, "windowResize");
  });
});

var resizeCharts = function(dialogHandle) {
  selector = ".chartDiv"
  if( dialogHandle !== undefined ) {
    selector = "#"+dialogHandle.attr("id")+" "+selector;
  }
  $(selector).each( function() {
    graph = $(this).data("chart");    
    enclosingDiv = $(graph).data("enclosingDiv");
    widthAdjustment = $(graph).data("widthAdjustment");
    resizeGraph( graph, enclosingDiv, widthAdjustment);
  });
}

function resizeGraph(graph, div, widthAdjustment)
{
  renderTo = $("#"+$(graph).data("renderTo"));
  console.log("width: "+$(div).width(), "renderto width:" + renderTo.width())
  graph.setSize( $(div).parent().width() + widthAdjustment, graph.chartHeight );
}
