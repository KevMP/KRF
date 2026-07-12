import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebarsApi: SidebarsConfig = {
  apiSidebar: [
    {
      type: 'category',
      label: 'Actor',
      items: [
        'Actor/actor-runtime',
        'Actor/actor',
        'Actor/actor-registry',
      ],
    },
    {
      type: 'category',
      label: 'Property',
      items: ['Property/property-controller'],
    },
    {
      type: 'category',
      label: 'Resource',
      items: ['Resource/resource-registry'],
    },
    {
      type: 'category',
      label: 'Tags',
      items: [
        'Tags/tag-registry',
        'Tags/tag-controller',
      ],
    },
    {
      type: 'category',
      label: 'Controllers',
      items: ['Controllers/controller-registry'],
    },
  ],
};

export default sidebarsApi;
