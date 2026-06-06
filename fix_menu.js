
const fs = require('fs');
let code = fs.readFileSync('lib/features/dashboard/presentation/dashboard_page.dart', 'utf-8');

const regex = /Widget _menuCard\(_DashboardMenu item\) \{[\s\S]*?\/\/\s*-- Bottom nav ---------------------------------------------------------------/;
const replacement = 'Widget _menuCard(_DashboardMenu item) {\n' +
'    final color = _menuAccent(item);\n' +
'    return NiceCard(\n' +
'      padding: const EdgeInsets.all(16),\n' +
'      onTap: item.onTap,\n' +
'      borderColor: color,\n' +
'      child: Column(\n' +
'        crossAxisAlignment: CrossAxisAlignment.start,\n' +
'        children: [\n' +
'          Container(\n' +
'            width: 48,\n' +
'            height: 48,\n' +
'            decoration: BoxDecoration(\n' +
'              borderRadius: BorderRadius.zero,\n' +
'              color: color.withOpacity(0.14),\n' +
'              border: Border.all(color: Colors.black, width: 2),\n' +
'            ),\n' +
'            child: Icon(item.icon, color: color, size: 24),\n' +
'          ),\n' +
'          const SizedBox(height: 14),\n' +
'          Expanded(\n' +
'            child: Column(\n' +
'              crossAxisAlignment: CrossAxisAlignment.start,\n' +
'              children: [\n' +
'                Text(\n' +
'                  item.title.toUpperCase(),\n' +
'                  maxLines: 2,\n' +
'                  style: TextStyle(\n' +
'                    fontSize: 14,\n' +
'                    fontWeight: FontWeight.w900,\n' +
'                    color: Theme.of(context).colorScheme.onSurface,\n' +
'                  ),\n' +
'                ),\n' +
'                const SizedBox(height: 6),\n' +
'                Expanded(\n' +
'                  child: Text(\n' +
'                    item.subtitle,\n' +
'                    maxLines: 3,\n' +
'                    overflow: TextOverflow.ellipsis,\n' +
'                    style: TextStyle(\n' +
'                      fontSize: 12,\n' +
'                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.60),\n' +
'                      height: 1.3,\n' +
'                      fontWeight: FontWeight.w600,\n' +
'                    ),\n' +
'                  ),\n' +
'                ),\n' +
'              ],\n' +
'            ),\n' +
'          ),\n' +
'        ],\n' +
'      ),\n' +
'    );\n' +
'  }\n\n' +
'  // -- Bottom nav ---------------------------------------------------------------';

if(code.match(regex)) {
    code = code.replace(regex, replacement);
    fs.writeFileSync('lib/features/dashboard/presentation/dashboard_page.dart', code);
    console.log('Fixed _menuCard');
} else {
    console.log('Could not find match');
}

