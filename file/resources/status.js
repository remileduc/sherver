/**
 * Enable POST request for status.
 *
 * You need a button with an id "#relaod" and a list with the id "#status".
 */
document.addEventListener("DOMContentLoaded", function() {
	var reload = document.querySelector("#reload");
	var text = reload.value;
	reload.addEventListener("click", function() {
		reload.disabled = true;
		reload.value = "Reloading...";
		var list = document.querySelector("#status");
		list.innerHTML = "...";
		fetch(".", {
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: "getstatus=status"
		}).then(function(response) {
			return response.text();
		}).then(function(contents) {
			list.innerHTML = contents;
			reload.disabled = false;
			reload.value = text;
		});
	});
});
