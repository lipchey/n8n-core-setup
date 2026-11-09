import {
	IExecuteFunctions,
	INodeExecutionData,
	INodeType,
	INodeTypeDescription,
	NodeOperationError,
} from 'n8n-workflow';

export class Example implements INodeType {
	description: INodeTypeDescription = {
		displayName: 'Example',
		name: 'example',
		icon: 'file:example.svg',
		group: ['transform'],
		version: 1,
		subtitle: '={{$parameter["operation"]}}',
		description: 'Project-local example node. Rename or remove.',
		defaults: { name: 'Example' },
		inputs: ['main'],
		outputs: ['main'],
		properties: [
			{
				displayName: 'Operation',
				name: 'operation',
				type: 'options',
				noDataExpression: true,
				options: [
					{ name: 'Echo', value: 'echo', description: 'Pass input through with a stamp', action: 'Echo input' },
					{ name: 'Uppercase', value: 'uppercase', description: 'Uppercase a string field', action: 'Uppercase a string' },
				],
				default: 'echo',
			},
			{
				displayName: 'Field',
				name: 'field',
				type: 'string',
				default: 'message',
				description: 'Property name in the input item to read/write',
				displayOptions: { show: { operation: ['uppercase'] } },
			},
		],
	};

	async execute(this: IExecuteFunctions): Promise<INodeExecutionData[][]> {
		const items = this.getInputData();
		const out: INodeExecutionData[] = [];

		for (let i = 0; i < items.length; i++) {
			const operation = this.getNodeParameter('operation', i) as string;
			const item = items[i].json;

			if (operation === 'echo') {
				out.push({ ...items[i], json: { ...item, _stamped: new Date().toISOString() }, pairedItem: { item: i } });
			} else if (operation === 'uppercase') {
				const field = this.getNodeParameter('field', i) as string;
				const value = item[field];
				if (typeof value !== 'string') {
					throw new NodeOperationError(this.getNode(), `Field "${field}" is not a string on item ${i}`);
				}
				out.push({ ...items[i], json: { ...item, [field]: value.toUpperCase() }, pairedItem: { item: i } });
			} else {
				throw new NodeOperationError(this.getNode(), `Unsupported operation "${operation}" on item ${i}`);
			}
		}

		return [out];
	}
}
