"use strict";

function Events ()
{
	function addTouchListener(node, allactions)
	{
		node.addEventListener("touchmove", (e) => {
			if (e.touches.length === 1 && Events.storage.target)
			{
				e.preventDefault();
				node.dispatchEvent(new MouseEvent("mousemove", e.touches[0]));
			}
		}, {passive: false});

		node.addEventListener("touchend", (e) => {
			if (e.touches.length === 0 && Events.storage.target)
			{
				e.preventDefault();
				node.dispatchEvent(new MouseEvent("mouseup", e.touches[0]));
			}
		}, {passive: false});

		if (allactions === true)
		{
			node.addEventListener("touchstart", (e) => {
				e.preventDefault();
				if (e.touches.length === 1)
					node.dispatchEvent(new MouseEvent("mousedown", e.touches[0]));
			}, {passive: false});

			node.addEventListener("touchcancel", (e) => {
				if (e.touches.length === 1 && Events.storage.target)
				{
					e.preventDefault();
					node.dispatchEvent(new MouseEvent("mouseout", e.touches[0]));
				}
			}, {passive: false});

			node.addEventListener("touchleave", (e) => {
				if (e.touches.length === 1 && Events.storage.target)
				{
					e.preventDefault();
					node.dispatchEvent(new MouseEvent("mouseout", e.touches[0]));
				}
			}, {passive: false});
		}
	}

	// drag & drop
	this.initDandD = function () // initialization
	{
		var nodes = document.querySelectorAll(".draggable");
		var posLeft = nodes[0].offsetLeft;
		var posTop = nodes[0].offsetTop;

		// we put the element at their position in absolute
		for (var currentNode of nodes)
		{
			if (currentNode.nodeType !== Node.ELEMENT_NODE)
				continue;

			currentNode.style.top = posTop + "px";
			currentNode.style.left = posLeft + "px";
			// add event listeners
			currentNode.addEventListener("mousedown", this.elementOnMouseDown);
			addTouchListener(currentNode, true);
		}
		// we put element style as absolute in the end to keep the flow
		for (var currentNode of nodes)
		{
			if (currentNode.nodeType === Node.ELEMENT_NODE)
				currentNode.style.position = "absolute";
		}

		// event listeners
		document.addEventListener("mouseup", this.elementOnMouseUp);
		//document.addEventListener("mouseout", this.elementOnMouseUp);
		document.addEventListener("mousemove", this.elementOnMouseMove);
		addTouchListener(document, false);
	};

	this.elementOnMouseUp = function (e)
	{
		Events.storage = {};
	};

	this.elementOnMouseDown = function (e)
	{
		if (!e.target.classList.contains("draggable") || e.button !== 0)
			return;

		var s = Events.storage;
		s.target = e.target;
		var pt = getComputedStyle(s.target, null);
		var marginLeft = parseInt(pt.marginLeft, 10);
		var marginTop = parseInt(pt.marginTop, 10);
		s.target.style.position = "absolute";
		s.offsetX = e.pageX - s.target.offsetLeft + marginLeft;
		s.offsetY = e.pageY - s.target.offsetTop + marginTop;
	};

	this.elementOnMouseMove = function (e)
	{
		var target = Events.storage.target;

		if (target)
		{
			target.style.top = e.pageY - Events.storage.offsetY + "px";
			target.style.left = e.pageX - Events.storage.offsetX + "px";
		}
	};
}

Events.storage = {}; // current moving node
