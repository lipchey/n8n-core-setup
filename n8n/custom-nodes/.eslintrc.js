module.exports = {
	root: true,
	env: { es2020: true, node: true },
	parser: '@typescript-eslint/parser',
	parserOptions: { sourceType: 'module', ecmaVersion: 2020 },
	ignorePatterns: ['dist/**', 'node_modules/**', '*.js'],
	overrides: [
		{
			files: ['package.json'],
			plugins: ['eslint-plugin-n8n-nodes-base'],
			extends: ['plugin:n8n-nodes-base/community'],
			rules: { 'n8n-nodes-base/community-package-json-name-still-default': 'off' },
		},
		{
			files: ['./credentials/**/*.ts'],
			plugins: ['eslint-plugin-n8n-nodes-base'],
			extends: ['plugin:n8n-nodes-base/credentials'],
			// Autofix mangles URL string values; the not-http-url rule already enforces the meaningful constraint.
			rules: { 'n8n-nodes-base/cred-class-field-documentation-url-miscased': 'off' },
		},
		{
			files: ['./nodes/**/*.ts'],
			plugins: ['eslint-plugin-n8n-nodes-base'],
			extends: ['plugin:n8n-nodes-base/nodes'],
		},
	],
};
