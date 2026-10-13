{% set g = helpers.getNodeByTag('OPNsense.clat.general') %}
{% if g.enabled|default("1") == "1" %}
clat_enable="YES"
{% else %}
clat_enable="NO"
{% endif %}
