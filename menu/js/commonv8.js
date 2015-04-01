// $Id: commonv8.js,v 8.37 2012/09/18 01:41:00 keiths Exp $
// 
// Copyright Opmantek Limited (www.opmantek.com)
// 
// ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
// 
// This file is part of Network Management Information System ("NMIS").
// 
// NMIS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// NMIS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with NMIS (most likely in a file named LICENSE).  
// If not, see <http://www.gnu.org/licenses/>
// 
// For further information on NMIS or for a license other than GPL please see
// www.opmantek.com or email contact@opmantek.com 
// 
// User group details:
// http://support.opmantek.com/users/ 
// 
// *****************************************************************************

// display the default NMIS opening page with menu bar

var nsRef = new Array();
var nsHtml;
var menu_url_base = '/menu8';
var widget_refresh_glob = 180;
var opCharts = false;
var config = 'Config';

// recreate vars that are expected

var namesAll = new Array();
var deviceContext = new Object();
deviceContext['Type'] = new Object();
deviceContext['Vendor'] = new Object();
deviceContext['Model'] = new Object();
deviceContext['Role'] = new Object();
deviceContext['Net'] = new Object();
deviceContext['Group'] = new Object();

// ===============================================
// jQuery document ready in nmiscgi.pl will call this first
// put all init calls here.

function commonv8Init(widget_refresh,configinit,registered,modules) {
	config = configinit;
	widget_refresh_glob = widget_refresh;

	// build namesAll
	
	var nodeInfoLength = nodeInfo.length;
	for(var nodeIndex = 0; nodeIndex < nodeInfoLength; nodeIndex++) {
		var node = nodeInfo[nodeIndex];
		var nodeName = node['name'];
		namesAll.push(nodeName);

		if( deviceContext.Type[node.Type] === undefined ) {
			deviceContext.Type[node.Type] = new Array();
		}
		deviceContext.Type[node.Type].push(nodeIndex);

		if( deviceContext.Vendor[node.Vendor] === undefined ) {
			deviceContext.Vendor[node.Vendor] = new Array();
		}
		deviceContext.Vendor[node.Vendor].push(nodeIndex);

		if( deviceContext.Model[node.Model] === undefined ) {
			deviceContext.Model[node.Model] = new Array();
		}
		deviceContext.Model[node.Model].push(nodeIndex);

		if( deviceContext.Role[node.Role] === undefined ) {
			deviceContext.Role[node.Role] = new Array();
		}
		deviceContext.Role[node.Role].push(nodeIndex);

		if( deviceContext.Net[node.Net] === undefined ) {
			deviceContext.Net[node.Net] = new Array();
		}
		deviceContext.Net[node.Net].push(nodeIndex);

		if( deviceContext.Group[node.Group] === undefined ) {
			deviceContext.Group[node.Group] = new Array();
		}
		deviceContext.Group[node.Group].push(nodeIndex);
	} 

 	// global error handler
 	
 	  $.ajaxSetup({
        error: function (x, e) {
            if (x.status == 0) {
                // This is really annoying......
                // alert('Network error');
            } else if (x.status == 404) {
                alert('404 Page not found');
            } else if (x.status == 500) {
                // assume msft brings error page back with a useful title
                var titleMatch = /(.*?)<\/title>/.exec(x.responseText);
                var titleString = titleMatch ? titleMatch[1] : '';
                alert('Oops!\n\n500 Internal Server Error\n\n' + titleString);
            } else if (e == 'parsererror') {
                alert('Error.\nParsing JSON Request failed.');
            } else if (e == 'timeout') {
                alert('Request Time out.');
            } else if (x.status == 405 ) {
            	// this is essentially a made-up status code that tells us to re-autheticate            	
            	document.location = document.location.href;
            } else {
                alert('Unkown error: ' + x.status + ' ' + x.statusText + '\n\n' + x.responseText);
            }
        }
        });
        
	// set up a object datastore on the NMISV8 tag
	// indexed by widget 'ID'
	// at logoff, prompt to save window layout
	// at login, look for a desktop profile by username,
	// for user 'nobody', or default opening page, set some useful defaults.
	// requires all 'ID" to be functionally distinct
	// same 'ID' same dialog window is updated.
	// different 'ID', create new dialog if not existing, or refresh existing.
	
	// require a minHeight so that the  dialog collapess to the select size on init.
	$('div#NMISV8').data('NMISV8defaultID', {
			id			: 'defaultID',
			options	: {
						id				:	'defaultID',
						title			:	'Default Title',
						url				: '#',
						prev_url	: '',
						width			: 'auto',
						height		: 'auto',
						minWidth	:	100,
						minHeight	: 40,
						autoOpen	: false,
						stack			: true,					// come to top when focused
						position	: [40,100]
			},
			widgetHandle	: '',
			status	: false
			});
		
	// TBD - read into here a JSON array of dialog options,
	// that were saved to server at logoff
	// therefore restoring the desktop as it was whenn logged off.
	// if a new install, or no options saved, or no JSON aray passed, then display the default front page with nav bar and jdMenu scripts
	

	// get and display top menubar	
	$.ajax({
		url			:	'menu.pl?conf=' + config + '&act=menu_bar_site',
		async		: false,
		dataType: "html",
		type 		: 'GET',
		cache		: false,
		success	: function(data) {
			$('div#menu_vh_site')[0].innerHTML = data;		// Use innerHTML to update the DOM only once
			$('ul.jd_menu').jdMenu();
		}
	});

	// launch the select node dialog
	if( savedWindowState === true ) {
		loadWindowState();
	}
	else {
		
		var logStart = 380;
		if ( useNewNetworkView ) {
			logStart = 400;
			createDialog({
				id		: 'ntw_view',
				url		: 'network.pl?conf=' + config + '&act=network_summary_view&refresh=' + widget_refresh,
				title	: 'Network Metrics and Health',
				width : 720,
				height: 320,
				position : [ 230, 70 ]
				});	
		}
		else {
			createDialog({
				id		: 'ntw_health',
				url		: 'network.pl?conf=' + config + '&act=network_summary_health&refresh=' + widget_refresh,
				title	: 'Network Status and Health',
				width : 850,
				height: 300,
				position : [ 230, 70 ]
				});	
		}

		createDialog({
			id		: 'ntw_metrics',
			url		: 'network.pl?conf=' + config + '&act=network_summary_metrics&refresh=' + widget_refresh,
			title	: 'Metrics',
			width	:	210,
			position : [ 10 , 70 ]
			});

		createDialog({
			id		: 'log_file_view',
			url		: 'logs.pl?conf=' + config + '&act=log_file_view&lines=50&logname=' + logName + '&refresh=' + widget_refresh,
			title	: 'Log of Network Events',
			width : 950,
			height: 380,
			position : [ 230, logStart ]
			});

		if ( displayCommunityWidget ) {
			createDialog({
				id       : 'ntw_rss',
 				url      : 'community_rss.pl?widget=true',
				title    : 'NMIS Community',
				width    : rssWidgetWidth,
				position : [ 10, 725 ]
				});
		}

		if ( modules.search("opMaps") > -1 && displayopMapsWidget ) {
			createDialog({
				id       : 'ntw_map',
				url      : '/cgi-omk/opMaps.pl?widget=true',
				title    : 'Network Map',
				width    : opMapsWidgetWidth,
				height   : opMapsWidgetHeight,
				position : [ 520, 250 ]
				});
		}
		if ( modules.search("opFlow") > -1 && displayopFlowWidget ) {			
			createDialog({
				id		: 'ntw_flowSummary',
				url		: '/cgi-omk/opFlow.pl?widget=true',
				title	: 'Application Flows',
				width	:	opFlowWidgetWidth,
				height:	opFlowWidgetHeight,
				position : [ 560, 420 ]
				});
		}

		// draw the quick search widget after the others.
		selectNodeOpen();	

	}
	
	if ( ! registered ) {
		createDialog({
			id       : 'cfg_registration',
			url      : 'registration.pl?conf=' + config,
			title    : 'NMIS Open Source Community',
			width	   : 420,
			position : [ 1000, 70 ]
			});
	}
	
	// except that the setup window should be the topmost dialog if active
	if ( displaySetupWidget ) 
	{
		createDialog({
			id       : 'cfg_setup',
 			url      : 'setup.pl?conf=' + config + '&amp;act=setup_menu&amp;widget=true',
			title    : 'Basic Setup',
			position : [ 5, 65 ]
		});
	}

};		// end init	
	
// ==================================

// function for all widget panel creates
// check for a saved window option list, that was pulled from the server when this session started
// and use those, then overwrite with defaults,  to fill in missing, the overwrite with command line options

function	createDialog(opt) {

	var dialogContainer;
	var dialogHandle;
	
	// log widget fixup
	// all log types to go to same widget
	// update title of widget to reflect log name
	// force all logs into one widget ID = 'log_file_view'
	if ( opt.url.indexOf('act=log') != -1 ) {
		opt.id = 'log_file_view';
	}

	// if no title configured 
	if ( ! opt.title && opt.id ) {
	 opt.title = opt.id ;
	}
	else if ( ! opt.title ) {
	 opt.title = 'Default Title';
	}
	
	// see if we have a data entry in our namespace
	var namespace = 'NMISV8' + opt.id;
	var objData = $('div#NMISV8').data(namespace);
	
	if ( ! objData  ) {
		// new dialog
		
			$('div#NMISV8').data(namespace, {
				id		:		opt.id,
				options	: opt,
				widgetHandle	:	 '',
				status	: false					// dialog does not exist as yet
		});
		objData = $('div#NMISV8').data(namespace);
		// fill out options with defaults
		var default_args = $('div#NMISV8').data('NMISV8defaultID').options;
		for(var index in default_args) {
			if (typeof objData.options[index] == "undefined") { objData.options[index] = default_args[index]; }
		}
	}
	// -------------------------------------------------------
	
	// set options array as passed to us as 'opt'
	// will merge command line options onto existing data store records
	
	// save current window url, so 'back' will rewrite with previous state
	if ( objData.options.url === opt.url ) {
			opt.prev_url = '';
	} else {
		opt.prev_url = objData.options.url;
	}
	
	for(var index in opt) {
		objData.options[index] = opt[index];
	};
	// read updated list of options back to current opt, so we have a full set in opt
	opt = objData.options; 
	
	// -----------------------------------------------------
	// test for window already open , otherwise recreate widget	
	if ( objData.status != true ) {	
	
		dialogContainer =	$('<div id="' + opt.id + '" style="display:none;"></div>');
		dialogContainer.appendTo('body');	
		dialogHandle = dialogContainer.dialog(opt);
		// tag this dialog with an ID so we know who it is when debugging
		dialogHandle.dialog("widget").attr( 'id' , opt.id );		
		// save the datastore dialog on the NMISV8 tag
		objData.widgetHandle = dialogHandle;
			
	} else {
		// window open aleady, just update the html
		dialogHandle = objData.widgetHandle;
	}	
	
	// update title of widget to reflect log name
	if ( opt.url.indexOf('act=log_file_view') != -1 ) {
		// log title same as log name
		opt.title =  'Log of ' + toTitleCase( gup( 'logname', opt.url) );
		objData.options.title = opt.title;
		dialogHandle.dialog( "option", "title", opt.title );
	}
	if ( opt.url.indexOf('act=log_list_view') != -1 ) {
		opt.title = 'List of Available Logs';
		objData.options.title = opt.title;
		dialogHandle.dialog( "option", "title", opt.title );
	}
		
	
	// get some additional content
	// but only if we have an URL !!
	if ( opt.url ) {
		if( opt.url.length < 600 )
		{
			$.ajax({
				url: opt.url,
				async: false,
				dataType: "html",
				type : 'GET',
				cache: false,
				success: function(data) {
					if( opt.url.indexOf("opFlow") !== -1 ) {
						splitData = data.split("\n");
						for(i = 0; i < splitData.length; i++) {
							if(splitData[i].indexOf('jquery') !== -1 ) {
								splitData[i] = "";
							}
						}
						data = splitData.join("\n");
					}
					dialogHandle.html(data);
					if ( opCharts == true && typeof(loadCharts) != undefined ) {
            loadCharts(dialogHandle);
          }
				}
			});	
		}
		else
		{
			newurl = opt.url.slice(0, opt.url.indexOf('?'));
			newdata = opt.url.slice(opt.url.indexOf('?')+1);
			$.ajax({
				url: newurl,
				data: newdata,
				async: false,
				dataType: "html",
				type : 'POST',
				cache: false,
				success: function(data) {
					dialogHandle.html(data);
					if ( opCharts == true && typeof(loadCharts) != undefined ) {
            loadCharts(dialogHandle);
          }
				}
			});	
			
		}	


		//====================================================
		// iterate over all the 'a'  tags, and add a click handler
		// if a attribute 'target=xxx', dont add the click handler, as we would
		// expect a new page to be opened for external content
		// add more rules here if required.

		$('a', dialogHandle ).each( function(){
			if ( ! $(this).attr('target') ) {
				// do not assign click handler if target is set
				// make sure we have an id on the 'a' tag, so the content replaces this dialog
				// if an 'id' already exits, leave as is.
				if ( !	$(this).attr('id') ) {
					$(this).attr('id', opt.id);
				}
				
				// nmisdev 24 AUg 2012 - change click function syntax to preferred context.
				//$(this).attr('onClick', "clickMenu(this);return false");
				$(this).click(function(){
					if( $(this).attr("href") === "#") {
						return false;
					}
					clickMenu(this);
					return false;
   			});

			};
		});

		//==============================================
		// form handler - find the inline javascript onclick get('nmis') - well, any handler that uses get()
		// add an hidden input tag, name = 'formID', value= 'opt.id', so we know what dialog we are in.
		// nmisdev 3Apr2012 use JQ 'after' with html string to avoid IE9 exception on appendTo
			$(':input[onclick]', dialogHandle ).each( function() {
		  	if ( $(this).attr('onclick').match(/get\(|javascript\:get\(/) ) {
		  		 		var newInput = '<input name="formID" type="hidden" value="'+opt.id+'">';
		  		 		$(this).after(newInput);
		  		}
			});

			// select onchange
				$('select[onchange]', dialogHandle ).each( function() {
		  		if ( $(this).attr('onchange').match(/^get|^javascript\:get/) ) {
		  			$(this).attr('id', opt.id);
		  		}
			});

	};	// end-if url


	//=============================================================
	// add a formatted time string to the dialog title
	
	var weekday=new Array(7);
		weekday[0]="Sun";
		weekday[1]="Mon";
		weekday[2]="Tue";
		weekday[3]="Wed";
		weekday[4]="Thu";
		weekday[5]="Fri";
		weekday[6]="Sat";
	
	var currentTime = new Date()
	var day = weekday[currentTime.getDay()]
	var hours = currentTime.getHours()
	var minutes = currentTime.getMinutes()
	if (minutes < 10) {	minutes = "0" + minutes; }
	var pDate = day + ' ' + hours + ":" + minutes ;
	
	// ============================================================
	// add in a 'New Page' icon/button that will open the page in a new window
	// 2012-12-06 keiths, fixed launch URL for widgets
	var newurl = opt.url.replace("widget=true","widget=false");
	if ( ! newurl.match(/widget=false/g) ) {
		newurl = newurl + '&widget=false';
	}	
	var dialogNewPage = '<a href="' + newurl + '" target="' + opt.id + '"><input type="image" title="New Page" name="' + opt.id + '" src="' + menu_url_base + '/img/slave.png" /></a>';

	// ============================================================
	// add in a 'back' icon/button that will update the dialog with the previous url, if reopened.
	var dialogHistory = '';
	if ( opt.prev_url ) {
		dialogHistory = '<input type="image" title="Back" name="' + opt.id + '" onClick="dialogHistoryClick(this.name);" src="' + menu_url_base + '/img/back.png" />';
	} 
	
	// ============================================================
	// add a refresh icon	
	var dialogRefresh = '<input type="image" title="Refresh" name="' + opt.id + '" onClick="dialogRefreshClick(this.name);" src="' + menu_url_base + '/img/refresh.png" />';
	
	// ============================================================
	// re-write the widget top banner line with date etc.	
	// this is a kludge, dialog.options should allow title text aligned right.
	// insert after the title span tag, that has our 'id' as a secure point of reference
	// could add other objects here, like refresh !!

	dialog = dialogHandle.dialog();
	titleBar = dialog.parents('.ui-dialog').find('.ui-dialog-titlebar');
	title = dialog.parents('.ui-dialog').find('.ui-dialog-title');

	$('span#timer_' + opt.id ).remove();
	title.css('width','auto');
	
	// insert + dialogNewPage + '&nbsp;' in below to get newPageButton
	var insertNewPage = dialogNewPage + '&nbsp;';
	var insertDate = '&nbsp;' + pDate;
	if ( opt.title == 'Quick Search' ) {
		insertNewPage = '';
		insertDate = '';
	}
	if ( opt.title == 'NMIS Community' ) {
		insertNewPage = '';
		insertDate = '';
	}
	newTitle = '<span id="timer_' + opt.id + '" class="ui-dialog-title" style="float:right; margin-right:25px;width:auto">' + insertNewPage + dialogRefresh + '&nbsp;' + dialogHistory + insertDate + '</span>';	
	$(newTitle)
    .appendTo(titleBar);


	// =================================================================
	// bind a handler to the close icon 'X', that will clean up after delete.
	if ( objData.status != true ) {	
		dialogHandle.bind( "dialogbeforeclose", function(event, ui) {
			var id = $(this).dialog("widget").attr( 'id' );
			var objData = $('div#NMISV8').data('NMISV8'+ id);

			// get and store where we might have been dragged too
			var pl = $(this).offset().left;
			var pt = $(this).offset().top;	

			objData.options.position = [ pl,pt ]  ;
			
			// drop refresh timer
			$.doTimeout( id );

			// leave our widget attribs on the DOM  , so we can reopen, just as it was when we were closed.
			// set a flag so this dormant state can be found.
			objData.status = false;
			return true;		// let the widget close.
		});

		// bind a handler on the 'close' event, just to clean up.
		// the before close was really just to get and store the widget position before it got closed.
		dialogHandle.bind( "dialogclose", function(event, ui) {
			var id = $(this).dialog("widget").attr( 'id' );
			var objData = $('div#NMISV8').data('NMISV8'+ id);
		// remove the widget, and the 'div id=xx></div> will magically appear as it was when we inserted this
			if ( opCharts == true && typeof(loadCharts) != undefined ) {
				unLoadCharts($(this));
			}
			$(this).dialog("destroy");
			$('div#'+id).hide().remove();
			return false;
		});
		
	}
	// dialog is open and ready for html
	objData.status = true;
	dialogHandle.dialog('open');

	//===============================================	
	// refresh dialog if url param refresh > 20.
	// configure time as seconds, not less than 20.. to avoid client overload ( dont know, not tested )
	//
	// using jQuery plugin for multiple setTimeout based on 'id'
	// http://benalman.com/projects/jquery-dotimeout-plugin/
	//
	// clear timer, then create.
	
	var refreshTime = gup( 'refresh', opt.url );
	
	if ( (typeof refreshTime !== 'undefined') && ( refreshTime > 10 )) {
		refreshTime *= 1000;
		$.doTimeout( opt.id );
		$.doTimeout( opt.id, refreshTime, function(){
				// only refresh current windows, this here to avoid refresh initiated window dialog opens
			 var namespace = 'NMISV8' + opt.id;
			 var objData = $('div#NMISV8').data(namespace);
			 if ( objData.status === true ) {
			 	if ( opCharts == true && typeof(loadCharts) != undefined ) {
					unLoadCharts(objData.widgetHandle);
				}
	 			createDialog(objData.options);
	 		};
	 	});
	} 
	else {
		dialogHandle.dialog( 'moveToTop' );
	};

	// ensure that the title is saved for refreshed requests, some of the logic above depends on its presence
	objData.options.title = opt.title;

	// special opFlow handing, it needs to load it's javascript a special way
	// if it's already loaded call refresh, if refresh is already defined then the javascript has already been loaded
	// the load will kick of a refresh because of the javascript onload section in opCommon.js
	// idendifying flow is done by looking for opFlow in the url, namespaces could also be used but there are several	
	if ( newurl.indexOf("opFlow") !== -1 ) {
		if( typeof(refresh) != "undefined" ) {
			refresh();
		}
		else {

			$.ajax({
				url			:	'/cgi-omk/opFlow.pl?summarise=60&widget=getJavascript',
				async		: false,
				dataType: "json",
				type 		: 'GET',
				cache		: false,
				success	: function(data) {
					for( i = 0; i < data.length; i++ ) {
						scriptData = data[i];
						var script   = document.createElement("script");
						script.type  = "text/javascript";

						if( scriptData.innerHTML !== undefined ) {
							script.innerHTML = scriptData.innerHTML;
						}
						if( scriptData.src !== undefined) {
							script.src   = scriptData.src;
						}

						document.body.appendChild(script);
					}			
				},
				error: function (xhr, ajaxOptions, thrownError) {
					// this error is expected from older versions of opflow
					console.log("opFlow requires updating to work with this version of NMIS");
				}
			});
		}
	}
	return dialogHandle;
};		// end createDialog


// ======================================================================

// back button
// previous url is expected to be saved on the window data store as options.prev_url
// this is called by the 'back icon' with the window ID, to refeence th data store.
function dialogHistoryClick(dhID) {
	
		 var namespace = 'NMISV8' + dhID;
			 var objData = $('div#NMISV8').data(namespace);
			 createDialog({
			 	id : dhID,
			 	url: objData.options.prev_url
			} );

};

// ======================================================================
function dialogRefreshClick(rfID) {
	
		 var namespace = 'NMISV8' + rfID;
			 var objData = $('div#NMISV8').data(namespace);
			 if ( opCharts == true && typeof(loadCharts) != undefined ) {
					unLoadCharts(objData.widgetHandle);
				}
			 createDialog({
			 	id : rfID,
	 			url: objData.options.url,
				title: objData.options.title,
			} );

};

// ======================================================================
// All href will be JQ to 'clickMenu', unless they were specifically targeted to a new window
// 
function clickMenu(e) {
	// nmisdev 24Aug 2012 fix title value to link text
	// IE9 suppports innerText, rest textContent
	var myHrefText  = e.textContent || e.innerText;

	// alert( 'clickMenu ' + 'id: ' + e.id + ' url: ' + e.href + ' title: ' + myHrefText );
	// ### 2012-02-29 keiths, for certain windows, constrain the height to prevent widget from getting too big.
	if ( e.href.indexOf("network_summary_group") != -1 ) {
		createDialog( {
			id 		: e.id,
			url 	: e.href,
			title	: myHrefText,
			height: 400
		});
	}
	else {
		createDialog( {
			id 		: e.id,
			url 	: e.href,
			title	: myHrefText
		});			
	}
	return false;
};


//=====================================
// test form handling
// could use this if next function get(o) doesnt suit your needs.

function showElements(oForm) {
   str = "Form Elements of form " + oForm.name + ": \n"
   for (i = 0; i < oForm.length; i++) 
      str += oForm.elements[i].name + '   v:' + oForm.elements[i].value + "\n"
   alert(str)
}



// ============================================================================
//
//javascript: get (Id)
// can only access 'Id' by using document.getElementById.
// must set elements id attributes if you want to be able to use this function.
// nmisdev 24 Aug 2012 set log dialogID and form IDcorrectly

function get(Id,optTrue,optFalse,evnt) {
	var getstr="";
	var dialogID;
	var f=document.getElementById(Id);

	for (i=0;i<f.elements.length;i++)  {
		var e=f.elements[i];

		if (e.tagName=="INPUT") {

			if (e.type == "hidden" && e.name == 'formID' ) {
					dialogID = e.value;
			}
			else {

				if (e.type=="text" || e.type=="textarea") {
					getstr+="&"+e.name+"="+encodeURIComponent(e.value);
				}

				if (e.type == "hidden") {
					getstr += "&"+ e.name + "=" + encodeURIComponent(e.value);
				}

				if (e.type=="checkbox") {
					if (e.checked) {
						getstr+="&"+e.name+"="+ encodeURIComponent(e.value);
					}
					else {
						getstr+="&"+e.name+"=";
					}
				}
			}

			if (e.type=="radio") {
				if (e.checked) {
					getstr+="&"+e.name+"="+encodeURIComponent(e.value);
				}
			}
		}

		if (e.tagName=="TEXTAREA") {
			getstr+="&"+e.name+"="+encodeURIComponent(e.value);
		}

		if (e.tagName=="SELECT") {
			var sel=e;
			if (sel.multiple==true) {
				var values='';
				var comma='';
				for (j=0; j<sel.options.length;j++) {
					if (sel.options[j].selected==true) {
						values+=comma+encodeURIComponent(sel.options[j].value);
						comma=',';
					}
				}
				if (values) {
					getstr+="&"+sel.name+"="+values;
				}
			}
			// nmisdev 2May2013 if nothing selected, selectedIndex = -1
			else { 
				if  (sel.selectedIndex==true) {
					getstr+="&"+sel.name+"="+sel.options[sel.selectedIndex].value;
				}
				else {
					getstr+="&"+sel.name+"="+encodeURIComponent(sel.value);
				}	
			}
			dialogID = e.id;
		}
	}


	if (optTrue) {
		getstr+='&'+optTrue+'=true';
	}

	if (optFalse) {
		getstr+='&'+optFalse+'=false';
	}

	if (evnt) {
		var pos=getMouse(evnt);
		var opt;
		if (optTrue) {
			opt=optTrue;
		}
		else{
			opt='mouse';
		}
		getstr+='&'+opt+'.x='+pos[0];
		getstr+='&'+opt+'.y='+pos[1];
	}

	var href=f.getAttribute('href');
	var url=href+getstr;

	// log what we got to the console for debugging.	
	// alert( 'id=' + dialogID ); alert( 'href=' + href ); alert( 'getstr=' + getstr );

	// NMIS Registration onClick handler
	// look for act=register in the url, and ajax post to Opmantek
	// then normal post to server with success or not of Opmantek post.

	var retval = '';
	if ( 'register' ==  gup( 'act', url )) {
		retval = OpmantekRegister( 'https://www.opmantek.com/cgi-bin/registration.cgi', getstr );
		if ( (typeof retval !== 'undefined') && ( retval.length )) {
			url=url + '&error=' + retval;
		}
	}
	// update widget with new content

	createDialog({ 
		id 		: dialogID,
		url 	: url
	});				// update dialog and show it
return false;

};

//==========================================

// post the registration details to Opmantek

	function OpmantekRegister( h, str ) {
		var result='';
		$.ajax({
			url			: h,
			data		: str,
			async		: false,
			type 		: 'POST',
			cache		: false,
			success	: function(data) {
				result = '';			// we dont expect any html to be returned
			},
			error	:		function(x,e){
				confirm(e);
				if(e=='parsererror'){
					result = 'Error.\nParsing JSON Request failed.';
				} else if (e=='timeout'){
					result = 'Request Time out.' ;
				} else if(x.status==0){
					result = 'You are offline!!\n Please Check Your Network.';					
					//alert( 'Status 0 !responseText: ' + x.responseText,  '!statusText': x.statusText, '@readyState' : x.readyState);					
					
				} else if(x.status==404){
					result = 'Requested URL not found.';
				} else if(x.status==500){
					result = 'Internel Server Error.' ;
				} else {
					result = 'Unknown Error.\n'+x.responseText;
				}
				alert( 'h='+ h +', str='+ str +', x.status='+ x.status +', x.statusText='+ x.statusText +', x.responseText='+ x.responseText );
			}
		});
		
		return result;
	}

//===========================================

// helper
function isEmpty(obj) { for(var i in obj) { return false; } return true; }

//================================================
// Telnet SSH access fixup
// onClick protocol handler for quicklinks.
// required to pass vars so javascript interpolation works.
// we are passed protocol name, target is quicksearch result box select

function makeLinks(u){
	if ( !u ) { return }
	var t = document.nodeSelectForm.names.options[document.nodeSelectForm.names.selectedIndex].value
	if ( !t ) { return }
	return u + t			// url or protocol telnet:// + target or host
};


// ===========================================================================


function setContentTitle(server) {
	$("span[id='serverName']").text( 'SERVER: ' + server );
}





//===========================================
// this opens and inits the floating select node dialog widget
//
// A global array to hold a reference to the arrays of nodenames,
// that are built in nmiscgi.pl, and passed to the browser as a JSON array
// each array is indexed by filter keyword.
// the filtername and list of filter keywords are posted to a select box.
// when that select box is clicked, the filtername is used as a key to the nsRef hash
// which returns an object ref to the set of elements that match that filter.


function selectNodeOpen() {
		
	var nodeSelect = createDialog({
										id		:	'nsWrapper',
										title	:	'Quick Search',
										url		:	'',
										width	:	210,
										position : [ 10, 355 ]
										});
	
	// define some additional content
	//<div class="tiny">&nbsp;</div>\

	var mycontent = '\
<div class="heading">Select Device by Context</div>\
<div id="nsContextMenu"></div>\
<form name="nsFormFilter">\
<div class="heading">Filter Device list by input string</div>\
<input type="text" id="nsInputMatch" onkeyup="nsInputMatchKey(this.value)" size="20">\
<div id="nsInputMatchResult"></div>\
<select id="names" name="names" multiple size="8" style="width:90%;"\
onclick="nodeInfoPanel( this.form.names.options[this.form.names.selectedIndex].value);return false;">\
</select>\
<br>\
<span id="matches" class="subtitle"></span>\
<br>\
<button type="button" style="float:left;" href="#"  onclick="selectNode_init(namesAll);">Reset the List</button>\
</form>\
</div>';
	
	nodeSelect.html(mycontent);
	nodeSelect.dialog('open');
	// populate  the lists
	selectNode_init_all();
	selectNode_init(namesAll);
		$("div#nsContextMenu > ul.jd_menu_vertical").jdMenu();

};
	
function selectNode_init_all() {
	$("div#nsContextMenu").empty();
	nsHtml = '<ul class="jd_menu jd_menu_vertical">';
	preFilter(deviceContext.Group, 'Group');
	preFilter(deviceContext.Model, 'Model');
	preFilter(deviceContext.Type, 'Type');
	preFilter(deviceContext.Role, 'Role');
	preFilter(deviceContext.Net, 'Net');
	preFilter(deviceContext.Vendor, 'Vendor');

	nsHtml += '</ul>';
	$("div#nsContextMenu").append(nsHtml);


};

function preFilter(filter, filtername) {
	// header
	nsHtml += '<li>' + filtername + '<ul>';
	// subitems
	// store the list name as an object indexed by the str name, so can be looked up by clickevent
	// nsRef[filtername] = filter;
	for (var n in filter) { // Each top-level entry
		var al = "<a name=" + filtername + " id=" + filtername + " onClick='nsClick(this);return false;'>" + n + "</a> (" + filter[n].length + ")";
		nsHtml += '<li>' + al + '</li>';
	}
	nsHtml += '</ul></li>';
};

// onClick event from nodeSelect menu url - text value is index of list items
// so just pass the array index, which will be a pointer to a list of nodes that matched this criteria
function nsClick(p) {
	//alert( p.name+','+p.innerHTML);
	
	var contextName = p.name;
	var filterName = p.innerHTML;

	// build up the array, no caching, so large # of nodes doesn't slow system down
	var searchArray = new Array();
	var loopLength = deviceContext[contextName][filterName].length;
	for( var i = 0; i < loopLength; i++ ) {
		var nodeInfoIndex = deviceContext[contextName][filterName][i];
		searchArray.push( namesAll[nodeInfoIndex] );
	}

	selectNode_init( searchArray );
};


//=============================================

// When a node is clicked on the 'All Node Selector' widget, laucnh a new widget with panel display from network
// display the node information window as a dialog
// parameter list 'node'
function nodeInfoPanel(nodename) {

	//var pserver = getServer();
	//var url ='network.pl?act=network_node_view&refresh=60&node=' + nodename + '&server=' + pserver + '';
	var url ='network.pl?act=network_node_view&conf=' + config + '&refresh=' + widget_refresh_glob +  '&node=' + encodeURIComponent(nodename) + '';
	
	// attention: the id must match what network.pl's selectLarge() uses!
	var node = nodename.split(".", 1 )[0];
	if ( node == '' ) {
		node = nodename;
	}
	// id attribs mustn't have spaces in them, start with letter, then letter/digits/-/_/:/., nothing else.
	var safenode = node.replace(/[^a-zA-Z0-9_:\.-]/g,'');

	var id = 'node_view_' + safenode;
	// alert( safenode );
	var opt = {
		id		: id,
		title	: nodename,
		url		: url,
		left	:	100,
		top		:	300
		};
	
		var nodeSelect = createDialog(opt);
		nodeSelect.dialog("open");
		return false;

};


//==================================================
// filter the nodelist by chars in nodeSelectInput


// set up arrays
// namesArray is list of Nodes, defined as '$varNodeArray' in nmiscgi.pl
//	namesArray = new Array("Andrew Haliburton","Brandon Christopher","Christopher Guest","Darius Allqonquin","Ellen Feis","Frenchie Flambee","Georg Hasselman","Haliburton Cheney","Ignacious Gracious","Jakob Nielsen","Keeley Gracious","Lyndon Larouche","Michael Jackson","Novus Primus","Optimus Shmoptimus","Plebian Sly","Quarrulous Ruler","Ravi Shankar","Steve Jobs","Thelonius Monk","Ursa Major","Venial Cavitus","Wallace Gromit","Xerius Guy","Yolan Nolan","Zehra Princess");
// namesArray is defined and populated by caller
// filter a list
d = document;
stregexp = new RegExp;
var namesArray = new Array();

function selectNode_init(newList) {
	namesArray = newList;
	tempArray  = new Array();
	remvdArray = new Array();
	
	// empty the node menu div
	$("#nsInputMatchResult").empty();
	
	// get select object
	selObj = d.getElementById("names");
	// rebuild the list
	buildOptions(namesArray);
	// clear the input box
	d.getElementById("nsInputMatch").value = "";
	// clear the last typed value
	lastVal = "";
	// write the number of matches
	writeMatches();
}


function nsInputMatchKey(str) {
	// if the length of str is 0, bypass everything else
	if (str.length == 0){
		buildOptions(namesArray);
		remvdArray.length = 0;
	}
	else {
		// clear tempArray
		tempArray.length = 0;
		// set up temporary array
		for (i=0;i<selObj.options.length;i++)	{
			tempArray[tempArray.length] = selObj.options[i].value;
		}
		// make case-insensitive regexp
		stregexp = new RegExp(str,"i");
		// remove appropriate item(s)
		if (lastVal.length < str.length) {
			for (j=selObj.options.length-1;j>-1;j--) {
				if (selObj.options[j].value.match(stregexp) == null)	{
					// remove the item
					tempArray.splice(j,1);
				}
			}
		}
		// add appropriate item(s)
		else	{
			// if a removed item matches the new pattern, add it to the list of names
			for (k=remvdArray.length-1;k>-1;k--) {
				tempName = remvdArray[k];
				if (tempName.match(stregexp) != null)	{
					tempArray[tempArray.length] = tempName;
				}
			}
			// sort the names array
			tempArray.sort();
		}
		// build the new select list
		buildOptions(tempArray);
	}
	// remember the last value on which we narrowed
	lastVal = str;
	// write the number of matches
	writeMatches();
}

function buildOptions(arrayName) {
	
	if ( arrayName == undefined ) { return; }
	// clear the select list
	selObj.options.length = 0;
	// build the select list
	for (l=0;l<arrayName.length;l++) {
		selObj.options[l] = new Option(arrayName[l])
	}
	// remember which items were removed
	buildRemvd();
}
function buildRemvd()	{
	// clear the removed items array
	remvdArray.length = 0;
	// build the removed items array
	for (m=namesArray.length-1;m>-1;m--) {
		if (namesArray[m].match(stregexp) == null) {
			// remember which item was removed
			remvdArray[remvdArray.length] = namesArray[m];
		}
	}
}

function writeMatches()	{
	if (selObj.options.length == 1) {
		d.getElementById("matches").innerHTML = "1 match";
	}
	else {
		d.getElementById("matches").innerHTML = selObj.options.length + " matches";
	}
}

// ========================================================
// used by events.pl to set events active/non-active.

function ExpandCollapse(bucket) {
	var img_id = bucket + "img";
	var img_element = document.getElementById(img_id);
	var bucket0 = bucket+"0";
	var display;
	if (document.getElementById(bucket0).style.display == '') {
		img_element.src = menu_url_base + "/img/sumdown.gif";
		display = 'none';
	}
	else {
		img_element.src = menu_url_base + "/img/sumup.gif";
		display = '';
	};

	for (var i=0;i<200;i++) {
		var id = bucket+i;
		var element = document.getElementById(id);
		if (element) {
			element.style.display = display;
		}
		else {
			break;
		}
	};
};


function checkBoxes(checkbox,name) {
	state = checkbox.checked;
	formcount = document.forms.length;
	for (j=0;j<formcount;j++) {
		elementcount = document.forms[j].elements.length;
		for (i=0;i<elementcount;i++)
		{
			if (document.forms[j].elements[i].name.substring(0,name.length)==name)
			document.forms[j].elements[i].checked = state;
		}
	}
};

/*=================================================================*/

function viewwndw(wndw,url,width,height)
{
	var attrib = "scrollbars=yes,resizable=yes,width=" + width + ",height=" + height;
	ViewWindow = window.open(url,wndw.replace(/\W+/g,'_'),attrib);
	ViewWindow.focus();
};
function viewdoc(url,width,height)
{
	viewwndw("ViewWindow",url,width,height)
};
function viewmsg(url,width,height)
{
	viewwndw("msgWindow",url,width,height)
};

// =================================================
function setTime() { return }; 				//TBD - fix me


// ================================================


// Read a page's GET URL variables and return them as an associative array.
	function	getUrlVars() {
			var vars = [], hash;
			var hashes = window.location.href.slice(window.location.href.indexOf('?') + 1).split('&');
			for(var i = 0; i < hashes.length; i++)
			{
				hash = hashes[i].split('=');
				vars.push(hash[0]);
				vars[hash[0]] = hash[1];
			}
			return vars;
		};


	
// ===================================================
		function toProperCase(s)
		{
			return s.toLowerCase().replace(/^(.)|\s(.)/g,
		function($1) { return $1.toUpperCase(); });
};

// ================================================
// parse the url given to us
// return the value for the requested paramater (name) in the passed in url ( href)

function gup( name, href ) {
  name = name.replace(/[\[]/,"\\\[").replace(/[\]]/,"\\\]");
  var regexS = "[\\?&]"+name+"=([^&#]*)";
  var regex = new RegExp( regexS );
  var results = regex.exec( href );
  if( results == null ) {
    return "";
  }
  else {
    return results[1];
	}
};

//===============================================

// set the pick list for the top nav bar 
// expect list of servers to focuse parent window on.
// ie portal application.

function getServer() {
	var server;
	var sl=document.getElementById("serverListName");
	// in case we cannot find div with id=serverListName, return localhost as a default
	if ( ! sl ) {
		return 'localhost';
	}

	for (var i=0; i<sl.options.length; i++){
 		if (sl.options[i].selected==true){
  		server=sl.options[i].value;
 		 break;
 		}
	}
	if ( !server ) {
		return 'localhost';
	}
	return server;
}


// utilites

function printObject(o) {

		var out = '';
			for ( var p in o ) {
				out += p + ': ' + o[p] + '\n';
			}
			alert(out);
	};


function toTitleCase(toTransform) {
  return toTransform.replace(/\b([a-z])/g, function (_, initial) {
      return initial.toUpperCase();
  });
}

$(function($) {
	$("#window_save").live( "click", function() {
		saveWindowState();
		return false;
	});
});
$(function($) {
	$("#window_clear").live( "click", function() {
		clearWindowState();
		return false;
	});
});

function loadWindowState() {	
	if( userWindowData ) {
		for( i = 0; i < userWindowData.length; i++ )
		{
			newWindowData = userWindowData[i];
			createDialog({
			id		: newWindowData.id,
			url		: newWindowData.url,
			title	: newWindowData.title,
			width : newWindowData.width,
			height: newWindowData.height,
			position : newWindowData.position
			});	
		}
	}
}

function saveWindowState() {
	windowObjects = $("div#NMISV8").data();
	windowData = [];
	
	jQuery.each(windowObjects, function(name, value) {
		objData = value;
		if ( objData.status === true ) {
			dialogHandle = objData.widgetHandle;
			thisWindow = { height: dialogHandle.dialog( "option", "height" ),
										 width: dialogHandle.dialog( "option", "width" ),
										 position: dialogHandle.dialog( "option", "position" ),
										 title: objData.options.title, 
										 url: objData.options.url, 
										 id: objData.options.id };
	    windowData.push( thisWindow );
		}
  });

	windowDataString = JSON.stringify({ windowData: windowData });	
	$.ajax({
    type: "POST",
		url:	'menu.pl',
    data: windowDataString,
    contentType: "application/json; charset=utf-8",
    dataType: "html"
  }); 
}

function clearWindowState() {
	windowDataString = JSON.stringify({ windowData: "" });
	$.ajax({
    type: "POST",
		url:	'menu.pl',
    data: windowDataString,
    contentType: "application/json; charset=utf-8",
    dataType: "html"
  }); 
}
