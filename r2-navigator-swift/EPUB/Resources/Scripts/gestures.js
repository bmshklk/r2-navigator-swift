(function() {

  var isTapping = false;
  var touchStartTime = null;
  var startX = 0;
  var startY = 0;
  var touchStartX = 0;
  var touchStartY = 0;


  document.addEventListener('touchstart', touchstart, false);
  document.addEventListener('touchend', touchend, false);

  function touchstart(event) {
    isTapping = (event.touches.length == 1);
    if (isInteractiveElement(event.target) || !isTapping) {
      return;
    }

    var touch = event.changedTouches[0];
    startX = touch.pageX;
    startY = touch.pageY;
    touchStartTime = Date.now();
    touchStartX = event.touches[0].clientX;
    touchStartY = event.touches[0].clientY;
  }

  window.addEventListener('DOMContentLoaded', function(event) {
    // If we don't set the CSS cursor property to pointer, then the click events are not triggered pre-iOS 13.
    document.body.style.cursor = 'pointer';

    document.addEventListener('click', onClick, false);
  });

  function onClick(event) {
    if (event.defaultPrevented || isInteractiveElement(event.target)) {
      return;
    }

    if (!window.getSelection().isCollapsed) {
      // There's an on-going selection, the tap will dismiss it so we don't forward it.
      return;
    }

    webkit.messageHandlers.tap.postMessage({
      "screenX": event.screenX,
      "screenY": event.screenY,
      "clientX": event.clientX,
      "clientY": event.clientY,
    });

    // We don't want to disable the default WebView behavior as it breaks some features without bringing any value.
//    event.stopPropagation();
//    event.preventDefault();
  }

  // See. https://github.com/JayPanoz/architecture/tree/touch-handling/misc/touch-handling
  function isInteractiveElement(element) {
    var interactiveTags = [
      'a',
      'audio',
      'button',
      'canvas',
      'details',
      'input',
      'label',
      'option',
      'select',
      'submit',
      'textarea',
      'video',
    ]
    if (interactiveTags.indexOf(element.nodeName.toLowerCase()) != -1) {
      return true;
    }

    // Checks whether the element is editable by the user.
    if (element.hasAttribute('contenteditable') && element.getAttribute('contenteditable').toLowerCase() != 'false') {
      return true;
    }

    // Checks parents recursively because the touch might be for example on an <em> inside a <a>.
    if (element.parentElement) {
      return isInteractiveElement(element.parentElement);
    }

    return false;
  }

})();
